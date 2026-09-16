import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../sync/outbox.dart';

/// Adds an expense, online or offline. Always writes to the local db
/// first as a [pending] row -- so the UI updates instantly and the same
/// code path works with or without connectivity -- then tries an
/// immediate sync; if that fails (offline, or the request errors) the row
/// just stays pending for the outbox to pick up later.
///
/// Supports all four of Spliit's split modes (evenly / by shares / by
/// percentage / by amount) plus excluding participants from "paid for",
/// matching the web app's "Advanced splitting options" -- see
/// decisions/feature-backlog.md for how this was scoped.
class AddExpenseScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final Group group;

  const AddExpenseScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
  });

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _amountController = TextEditingController();
  String? _paidBy;
  bool _saving = false;
  String? _splitError;

  SplitMode _splitMode = SplitMode.evenly;
  late final Map<String, bool> _includedInSplit = {
    for (final p in widget.group.participants) p.id: true,
  };
  // Per-participant text controllers for the non-evenly modes -- shares
  // (any positive integer), percentage (0-100, must sum to 100), or
  // amount (dollars, must sum to the total). Kept for every participant
  // regardless of _includedInSplit so toggling inclusion doesn't lose
  // what was typed.
  late final Map<String, TextEditingController> _splitControllers = {
    for (final p in widget.group.participants) p.id: TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    if (widget.group.participants.isNotEmpty) {
      _paidBy = widget.group.participants.first.id;
    }
  }

  @override
  void dispose() {
    for (final c in _splitControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<Participant> get _includedParticipants =>
      widget.group.participants.where((p) => _includedInSplit[p.id] ?? false).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add expense')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountController,
                decoration: const InputDecoration(labelText: 'Amount', prefixText: '\$'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}), // amount feeds the by-amount hint below
                validator: (v) {
                  final parsed = double.tryParse(v ?? '');
                  if (parsed == null || parsed <= 0) return 'Enter a valid amount';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _paidBy,
                decoration: const InputDecoration(labelText: 'Paid by'),
                items: widget.group.participants
                    .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                    .toList(),
                onChanged: (v) => setState(() => _paidBy = v),
                validator: (v) => v == null ? 'Required' : null,
              ),
              const SizedBox(height: 24),
              Text('Paid for', style: Theme.of(context).textTheme.titleMedium),
              for (final p in widget.group.participants) _paidForRow(p),
              const SizedBox(height: 12),
              DropdownButtonFormField<SplitMode>(
                initialValue: _splitMode,
                decoration: const InputDecoration(labelText: 'Split mode'),
                items: const [
                  DropdownMenuItem(value: SplitMode.evenly, child: Text('Evenly')),
                  DropdownMenuItem(
                      value: SplitMode.byShares, child: Text('Unevenly – By shares')),
                  DropdownMenuItem(
                      value: SplitMode.byPercentage,
                      child: Text('Unevenly – By percentage')),
                  DropdownMenuItem(
                      value: SplitMode.byAmount, child: Text('Unevenly – By amount')),
                ],
                onChanged: (v) => setState(() {
                  _splitMode = v ?? SplitMode.evenly;
                  _splitError = null;
                }),
              ),
              if (_splitError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_splitError!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _paidForRow(Participant p) {
    final included = _includedInSplit[p.id] ?? false;
    return Row(
      children: [
        Expanded(
          child: CheckboxListTile(
            value: included,
            onChanged: (v) => setState(() => _includedInSplit[p.id] = v ?? false),
            title: Text(p.name),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (included && _splitMode != SplitMode.evenly)
          SizedBox(
            width: 90,
            child: TextFormField(
              controller: _splitControllers[p.id],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                prefixText: _splitMode == SplitMode.byAmount ? '\$' : null,
                suffixText: _splitMode == SplitMode.byPercentage ? '%' : null,
              ),
            ),
          ),
      ],
    );
  }

  /// Builds the paidFor list for the current split mode, or returns null
  /// (and sets [_splitError]) if the entered per-participant values don't
  /// add up. Evenly needs no per-participant input at all -- every
  /// included participant just gets an equal weight.
  List<ExpenseShare>? _buildPaidFor(int amountCents) {
    final included = _includedParticipants;
    if (included.isEmpty) {
      setState(() => _splitError = 'Select at least one participant');
      return null;
    }

    if (_splitMode == SplitMode.evenly) {
      return included.map((p) => ExpenseShare(participantId: p.id, shares: 1)).toList();
    }

    if (_splitMode == SplitMode.byShares) {
      final shares = <ExpenseShare>[];
      for (final p in included) {
        final value = int.tryParse(_splitControllers[p.id]!.text.trim());
        if (value == null || value <= 0) {
          setState(() => _splitError = '${p.name}: enter a whole number of shares');
          return null;
        }
        shares.add(ExpenseShare(participantId: p.id, shares: value));
      }
      return shares;
    }

    if (_splitMode == SplitMode.byPercentage) {
      final shares = <ExpenseShare>[];
      var total = 0;
      for (final p in included) {
        final value = int.tryParse(_splitControllers[p.id]!.text.trim());
        if (value == null || value < 0) {
          setState(() => _splitError = '${p.name}: enter a percentage');
          return null;
        }
        total += value;
        shares.add(ExpenseShare(participantId: p.id, shares: value));
      }
      if (total != 100) {
        setState(() => _splitError = 'Percentages must add up to 100 (currently $total)');
        return null;
      }
      return shares;
    }

    // byAmount
    final shares = <ExpenseShare>[];
    var totalCents = 0;
    for (final p in included) {
      final value = double.tryParse(_splitControllers[p.id]!.text.trim());
      if (value == null || value < 0) {
        setState(() => _splitError = '${p.name}: enter an amount');
        return null;
      }
      final cents = (value * 100).round();
      totalCents += cents;
      shares.add(ExpenseShare(participantId: p.id, shares: cents));
    }
    if (totalCents != amountCents) {
      final diff = ((amountCents - totalCents) / 100).toStringAsFixed(2);
      setState(() =>
          _splitError = 'Amounts must add up to the total (off by \$$diff)');
      return null;
    }
    return shares;
  }

  Future<void> _save() async {
    setState(() => _splitError = null);
    if (!_formKey.currentState!.validate()) return;

    final amountCents = (double.parse(_amountController.text) * 100).round();
    final paidFor = _buildPaidFor(amountCents);
    if (paidFor == null) return;

    setState(() => _saving = true);

    final expense = Expense(
      id: const Uuid().v4(),
      groupId: widget.group.id,
      title: _titleController.text.trim(),
      amountCents: amountCents,
      paidBy: _paidBy!,
      paidFor: paidFor,
      splitMode: _splitMode,
      date: DateTime.now(),
      pending: true,
    );

    // Written locally first -- this succeeds regardless of connectivity,
    // which is the entire point. The outbox (triggered by the caller
    // after this returns) is what attempts the real sync.
    await widget.db.insertPending(expense);

    if (mounted) Navigator.of(context).pop(true);
  }
}
