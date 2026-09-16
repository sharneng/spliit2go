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
/// v1 scope: evenly split among every group participant, one payer. Exact
/// per-person amounts (SplitMode.byAmount) -- what the CSV importer needs
/// for reconstructing uneven Splitwise splits -- isn't exposed in this UI
/// yet.
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

  @override
  void initState() {
    super.initState();
    if (widget.group.participants.isNotEmpty) {
      _paidBy = widget.group.participants.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add expense')),
      body: Padding(
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final amountCents = (double.parse(_amountController.text) * 100).round();
    final evenShares = widget.group.participants
        .map((p) => ExpenseShare(participantId: p.id, shares: 1))
        .toList();

    final expense = Expense(
      id: const Uuid().v4(),
      groupId: widget.group.id,
      title: _titleController.text.trim(),
      amountCents: amountCents,
      paidBy: _paidBy!,
      paidFor: evenShares,
      splitMode: SplitMode.evenly,
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
