import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/active_user.dart';
import '../sync/outbox.dart';

/// Adds -- or, given [existingExpense], edits -- an expense. An expense
/// with [Expense.isReimbursement] set is a settlement/"paid back"
/// entry -- same fields, same screen, no special-casing needed here.
/// (balances_screen.dart's own "mark as paid" writes a pending
/// reimbursement expense directly rather than opening this screen, but
/// it's still this same [Expense] shape -- see that file's doc comment.)
/// Renamed from AddExpenseScreen/add_expense_screen.dart (issue #21) once
/// "add expense screen" stopped describing what this actually covers.
///
/// Adding works online or offline: it always writes to the local db first
/// as a [pending] row -- so the UI updates instantly and the same code
/// path works with or without connectivity -- then tries an immediate
/// sync; if that fails (offline, or the request errors) the row just
/// stays pending for the outbox to pick up later.
///
/// Editing (issue #17) is **online-only** -- there's no offline-edit
/// queueing path (see decisions/mobile-platform.md's view+add-only
/// offline scope) -- and saves straight to the server via
/// [SpliitClient.updateExpense]. IMPORTANT: Spliit's server has no
/// conflict-prevention for edits at all (see that method's doc comment)
/// -- the only mitigation this app makes is that callers should fetch the
/// expense fresh (via [SpliitClient.fetchExpense]) immediately before
/// opening this screen in edit mode, to keep the editing window as short
/// as possible. This screen itself doesn't re-fetch; it trusts whatever
/// [existingExpense] it's given.
///
/// Supports all four of Spliit's split modes (evenly / by shares / by
/// percentage / by amount) plus excluding participants from "paid for",
/// matching the web app's "Advanced splitting options" -- see
/// decisions/feature-backlog.md for how this was scoped.
///
/// Field set matches Spliit's own add/edit expense form (issue #16):
/// title, amount, category, paid by, paid for/split mode, date, "paid
/// in" a different currency, reimbursement flag, save-as-default-split,
/// recurrence, and notes. "Attach documents" is the one field
/// deliberately not implemented -- see the note next to
/// [_documentsPlaceholder] below for why.
class ExpenseScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final Group group;
  /// This device's saved "active user" (see SettingsService), if any --
  /// used to default "Paid by" via [resolveDefaultPaidBy]. Passed in
  /// rather than loaded here so this screen doesn't need
  /// SharedPreferences of its own to test. Ignored when [existingExpense]
  /// is set -- edit mode prefills "Paid by" from the expense itself.
  final String? initialPaidBy;

  /// When set, this screen edits [existingExpense] in place instead of
  /// creating a new one -- see the class doc comment for edit mode's
  /// online-only, no-conflict-prevention caveats.
  final Expense? existingExpense;

  const ExpenseScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.initialPaidBy,
    this.existingExpense,
  });

  bool get isEditing => existingExpense != null;

  @override
  State<ExpenseScreen> createState() => _ExpenseScreenState();
}

class _ExpenseScreenState extends State<ExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();
  final _originalAmountController = TextEditingController();
  final _originalCurrencyController = TextEditingController();
  String? _paidBy;
  bool _saving = false;
  String? _splitError;
  String? _saveError;

  DateTime _date = DateTime.now();
  bool _isReimbursement = false;
  bool _saveDefaultSplittingOptions = false;
  RecurrenceRule _recurrenceRule = RecurrenceRule.none;
  bool _paidInOtherCurrency = false;

  // Falls back to just "General" (Spliit's own default, id 0) until/unless
  // a live categories.list succeeds -- offline or a slow first load
  // shouldn't block adding an expense on having a full category list.
  Map<int, String> _categories = const {0: 'General'};
  int _category = 0;

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
    final existing = widget.existingExpense;
    if (existing != null) {
      _prefillFrom(existing);
    } else {
      _paidBy = resolveDefaultPaidBy(
        activeUserId: widget.initialPaidBy,
        participants: widget.group.participants,
      );
    }
    _loadCategories();
  }

  /// Fills every control from [e] -- edit mode's starting point. Runs
  /// once, in [initState]; this screen doesn't re-sync with a changing
  /// [existingExpense] afterwards.
  void _prefillFrom(Expense e) {
    _titleController.text = e.title;
    _amountController.text = (e.amountCents / 100).toStringAsFixed(2);
    _notesController.text = e.notes;
    _paidBy = e.paidBy;
    _category = e.category;
    _date = e.date;
    _isReimbursement = e.isReimbursement;
    _recurrenceRule = e.recurrenceRule;
    _splitMode = e.splitMode;

    for (final p in widget.group.participants) {
      _includedInSplit[p.id] = false;
    }
    for (final share in e.paidFor) {
      _includedInSplit[share.participantId] = true;
      final controller = _splitControllers[share.participantId];
      if (controller == null) continue;
      controller.text = switch (e.splitMode) {
        SplitMode.byAmount => (share.shares / 100).toStringAsFixed(2),
        // Basis points on the wire -> whole percent in the UI -- inverse
        // of the x100 done in _buildPaidFor.
        SplitMode.byPercentage => (share.shares / 100).round().toString(),
        _ => share.shares.toString(),
      };
    }

    if (e.originalAmountCents != null && e.originalCurrency != null) {
      _paidInOtherCurrency = true;
      _originalAmountController.text = (e.originalAmountCents! / 100).toStringAsFixed(2);
      _originalCurrencyController.text = e.originalCurrency!;
    }

    // Make sure the category dropdown always has an entry for whatever
    // this expense is actually filed under, even before (or if)
    // _loadCategories' live fetch ever succeeds -- a DropdownButtonFormField
    // whose initialValue isn't among its items throws.
    if (!_categories.containsKey(_category)) {
      _categories = {..._categories, _category: 'Category $_category'};
    }
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await widget.client.fetchCategories();
      if (!mounted || cats.isEmpty) return;
      setState(() {
        _categories = {...cats};
        if (!_categories.containsKey(_category)) {
          _categories = {..._categories, _category: 'Category $_category'};
        }
      });
    } catch (_) {
      // Offline or the server's unreachable -- keep the General-only
      // fallback (plus whatever category id an edited expense already
      // has, added above) so the form still works without connectivity.
    }
  }

  @override
  void dispose() {
    for (final c in _splitControllers.values) {
      c.dispose();
    }
    _notesController.dispose();
    _originalAmountController.dispose();
    _originalCurrencyController.dispose();
    super.dispose();
  }

  List<Participant> get _includedParticipants =>
      widget.group.participants.where((p) => _includedInSplit[p.id] ?? false).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.isEditing ? 'Edit expense' : 'Add expense')),
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
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Date'),
                  child: Text(_formatDate(_date)),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _categories.containsKey(_category) ? _category : null,
                decoration: const InputDecoration(labelText: 'Category'),
                items: _categories.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? 0),
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
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _paidInOtherCurrency,
                onChanged: (v) => setState(() => _paidInOtherCurrency = v ?? false),
                title: const Text('Paid in a different currency'),
                subtitle: Text('Group currency: ${widget.group.currency}'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              if (_paidInOtherCurrency) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _originalAmountController,
                        decoration: const InputDecoration(labelText: 'Original amount'),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        validator: (v) {
                          if (!_paidInOtherCurrency) return null;
                          final parsed = double.tryParse(v ?? '');
                          if (parsed == null || parsed <= 0) return 'Enter a valid amount';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 100,
                      child: TextFormField(
                        controller: _originalCurrencyController,
                        decoration: const InputDecoration(labelText: 'Currency'),
                        textCapitalization: TextCapitalization.characters,
                        validator: (v) {
                          if (!_paidInOtherCurrency) return null;
                          return (v == null || v.trim().isEmpty) ? 'Required' : null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              CheckboxListTile(
                value: _isReimbursement,
                onChanged: (v) => setState(() => _isReimbursement = v ?? false),
                title: const Text('This is a reimbursement'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              CheckboxListTile(
                value: _saveDefaultSplittingOptions,
                onChanged: (v) => setState(() => _saveDefaultSplittingOptions = v ?? false),
                title: const Text('Save as default splitting options'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<RecurrenceRule>(
                initialValue: _recurrenceRule,
                decoration: const InputDecoration(labelText: 'Repeat'),
                items: const [
                  DropdownMenuItem(value: RecurrenceRule.none, child: Text('Does not repeat')),
                  DropdownMenuItem(value: RecurrenceRule.daily, child: Text('Daily')),
                  DropdownMenuItem(value: RecurrenceRule.weekly, child: Text('Weekly')),
                  DropdownMenuItem(value: RecurrenceRule.monthly, child: Text('Monthly')),
                ],
                onChanged: (v) => setState(() => _recurrenceRule = v ?? RecurrenceRule.none),
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
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(labelText: 'Notes'),
                maxLines: 3,
                maxLength: 5000, // matches Spliit's EXPENSE_NOTES_MAX
              ),
              _documentsPlaceholder(context),
              if (_saveError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_saveError!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
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

  /// "Attach documents" is the one field from issue #16 deliberately not
  /// implemented here. Spliit's own upload flow needs a presigned-S3
  /// upload (next-s3-upload, capped at 5MB/file) -- a substantial, separate
  /// subsystem this app has no offline-queueing story for yet (what
  /// happens to a picked file if it's attached while offline and the
  /// outbox tries to replay the create later?). Shown as a disabled row
  /// rather than silently omitted, so it reads as "not yet supported"
  /// instead of looking like an oversight.
  Widget _documentsPlaceholder(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(Icons.attach_file, color: Theme.of(context).disabledColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Attach documents – not yet supported in this app',
              style: TextStyle(color: Theme.of(context).disabledColor),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
  ///
  /// For [SplitMode.byPercentage], the UI takes/validates 0-100 whole
  /// percentages (summing to 100) but the returned [ExpenseShare.shares]
  /// are in basis points (percentage x 100, summing to 10000) -- that's
  /// what Spliit's server actually expects on the wire (its
  /// expenseFormSchema's percentageSum check), confirmed against a real
  /// server's balance math going wrong when this app sent raw 0-100
  /// values -- see github.com/sharneng/spliit2go/issues/18 and issue #20.
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
        // Wire format is basis points (percentage x 100), not the raw
        // 0-100 the user types -- see this method's doc comment.
        shares.add(ExpenseShare(participantId: p.id, shares: value * 100));
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
    setState(() {
      _splitError = null;
      _saveError = null;
    });
    if (!_formKey.currentState!.validate()) return;

    final amountCents = (double.parse(_amountController.text) * 100).round();
    final paidFor = _buildPaidFor(amountCents);
    if (paidFor == null) return;

    int? originalAmountCents;
    String? originalCurrency;
    double? conversionRate;
    if (_paidInOtherCurrency) {
      final originalAmount = double.parse(_originalAmountController.text.trim());
      originalAmountCents = (originalAmount * 100).round();
      originalCurrency = _originalCurrencyController.text.trim().toUpperCase();
      // groupAmount = originalAmount * conversionRate (Spliit's own
      // convention -- see src/lib/currency-conversion.ts upstream).
      conversionRate = amountCents / originalAmountCents;
    }

    setState(() => _saving = true);

    if (widget.isEditing) {
      await _saveEdit(
        amountCents: amountCents,
        paidFor: paidFor,
        originalAmountCents: originalAmountCents,
        originalCurrency: originalCurrency,
        conversionRate: conversionRate,
      );
    } else {
      await _saveNew(
        amountCents: amountCents,
        paidFor: paidFor,
        originalAmountCents: originalAmountCents,
        originalCurrency: originalCurrency,
        conversionRate: conversionRate,
      );
    }
  }

  Future<void> _saveNew({
    required int amountCents,
    required List<ExpenseShare> paidFor,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
  }) async {
    final expense = Expense(
      id: const Uuid().v4(),
      groupId: widget.group.id,
      title: _titleController.text.trim(),
      amountCents: amountCents,
      paidBy: _paidBy!,
      paidFor: paidFor,
      splitMode: _splitMode,
      category: _category,
      notes: _notesController.text.trim(),
      date: _date,
      isReimbursement: _isReimbursement,
      recurrenceRule: _recurrenceRule,
      originalAmountCents: originalAmountCents,
      originalCurrency: originalCurrency,
      conversionRate: conversionRate,
      pending: true,
    );

    // Written locally first -- this succeeds regardless of connectivity,
    // which is the entire point. The outbox (triggered by the caller
    // after this returns) is what attempts the real sync.
    await widget.db.insertPending(expense);

    if (mounted) Navigator.of(context).pop(true);
  }

  /// Online-only (see class doc comment): no local pending row, no
  /// outbox -- just a direct [SpliitClient.updateExpense] call. On
  /// failure (most commonly: offline), stays on the form with an error
  /// rather than silently queuing anything, since there's no queueing
  /// path for edits.
  Future<void> _saveEdit({
    required int amountCents,
    required List<ExpenseShare> paidFor,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
  }) async {
    try {
      await widget.client.updateExpense(
        groupId: widget.group.id,
        expenseId: widget.existingExpense!.id,
        title: _titleController.text.trim(),
        amountCents: amountCents,
        paidBy: _paidBy!,
        paidFor: paidFor,
        splitMode: _splitMode,
        category: _category,
        notes: _notesController.text.trim(),
        date: _date,
        isReimbursement: _isReimbursement,
        recurrenceRule: _recurrenceRule,
        saveDefaultSplittingOptions: _saveDefaultSplittingOptions,
        originalAmountCents: originalAmountCents,
        originalCurrency: originalCurrency,
        conversionRate: conversionRate,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = "Couldn't save: needs a connection to edit an expense ($e)";
      });
    }
  }
}
