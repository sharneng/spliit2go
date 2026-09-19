import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../models/default_split.dart';
import '../l10n/context_l10n.dart';
import '../services/active_user.dart';
import '../services/expense_shares.dart';
import '../sync/outbox.dart';
import '../utils/decimal_input.dart';
import '../widgets/currency_picker.dart';
import '../widgets/category_icon.dart';

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

  /// A starting draft for a brand-new expense (ignored when
  /// [existingExpense] is set) -- every field is pre-filled from it, but
  /// saving still creates a new expense with a fresh id via the normal
  /// add path (local pending row + outbox), unlike [existingExpense]'s
  /// online-only update. Used by balances_screen.dart's "mark as paid"
  /// (issue #22) to open this screen pre-filled with the suggested
  /// settlement's amount/payer/payee/title rather than recording it
  /// directly, so the amount can be edited for a partial payment --
  /// matching the web/iOS apps' own settle-up flow.
  final Expense? initialDraft;

  const ExpenseScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.initialPaidBy,
    this.existingExpense,
    this.initialDraft,
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
  String? _saveError;

  /// True once Save has been pressed at least once -- gates whether the
  /// "Paid for" footer shows a blocking validation error or the running
  /// "still to allocate" hint (issue #29, decisions/paid-for-split-ux-spec.md
  /// section 6): a fresh form shouldn't greet the user with red text
  /// before they've done anything.
  bool _hasAttemptedSave = false;

  DateTime _date = DateTime.now();
  bool _isReimbursement = false;
  bool _saveDefaultSplittingOptions = false;
  RecurrenceRule _recurrenceRule = RecurrenceRule.none;
  bool _paidInOtherCurrency = false;
  String? _originalCurrencyError;

  /// Whether [widget.group] has a real ISO currency code (as opposed to
  /// a free-typed custom symbol with no code) -- exactly the condition
  /// the web app's expense-form.tsx uses to decide whether the
  /// original-currency field is a picker at all, since there's no
  /// exchange rate to convert against for a currency Spliit doesn't
  /// recognize.
  bool get _hasGroupCurrencyCode =>
      widget.group.currencyCode != null && widget.group.currencyCode!.isNotEmpty;

  // Falls back to just "General" (Spliit's own default, id 0) until/unless
  // a live categories.list succeeds -- offline or a slow first load
  // shouldn't block adding an expense on having a full category list.
  List<Category> _categories = const [
    Category(id: 0, name: 'General', grouping: 'Uncategorized'),
  ];
  int _category = 0;

  /// The currently-selected category, falling back to a synthesized
  /// placeholder if [_category] isn't (yet, or ever) in [_categories] --
  /// keeps the picker's "current selection" display never crashing on a
  /// category id this device hasn't fetched a name for.
  Category get _selectedCategory => _categories.firstWhere(
        (c) => c.id == _category,
        orElse: () => Category(id: _category, name: 'Category $_category', grouping: 'Other'),
      );

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
    // Every field starts at the literal text "1" -- not a computed even
    // split, not blank -- matching spliit-ios's own default (issue #29
    // section 5). Overwritten by _prefillFrom for edit/draft mode, or by
    // _applyDefaultSplit for a brand-new expense with a remembered split.
    for (final p in widget.group.participants) p.id: TextEditingController(text: '1'),
  };

  @override
  void initState() {
    super.initState();
    final existing = widget.existingExpense;
    final draft = widget.initialDraft;
    if (existing != null) {
      _prefillFrom(existing);
    } else if (draft != null) {
      // Pre-fills the same way edit mode does -- draft mode only differs
      // in _save() (new id, normal add path), not in what's shown.
      _prefillFrom(draft);
    } else {
      _paidBy = resolveDefaultPaidBy(
        activeUserId: widget.initialPaidBy,
        participants: widget.group.participants,
      );
      // Only for a plain brand-new expense -- not for edit (_prefillFrom
      // above already set the real split) and not for a draft like
      // balances_screen's "mark as paid" (its reimbursement split is the
      // whole point of that flow and shouldn't be overridden by a
      // remembered default -- isSplitWorthRemembering excludes
      // reimbursements for the same reason on the write side).
      _loadDefaultSplit();
    }
    _loadCategories();
  }

  /// Applies this group's remembered "Paid for" split (issue #29,
  /// decisions/paid-for-split-ux-spec.md section 7), if one exists and
  /// still applies to the group's current participants. Async because
  /// reading it means a DB query -- same fire-and-forget-with-setState
  /// pattern as [_loadCategories], so a slow read never blocks the form
  /// from being usable in the meantime (it just starts as plain
  /// "everyone, evenly" and switches over once the read completes).
  Future<void> _loadDefaultSplit() async {
    final split = await widget.db.defaultSplitFor(widget.group.id);
    if (!mounted || split == null || !split.appliesTo(widget.group.participants)) return;
    setState(() {
      _splitMode = split.splitMode;
      final shares = split.shares;
      if (shares == null) return; // "everyone" (or Amount) -- defaults already reflect that.
      for (final p in widget.group.participants) {
        final value = shares[p.id];
        _includedInSplit[p.id] = value != null;
        if (value == null) continue;
        _splitControllers[p.id]!.text = switch (split.splitMode) {
          // Inverse of the x100 done in _buildPaidFor -- same conversion
          // _prefillFrom uses for an edited expense's Shares/Percentage
          // values (issue #34: both are x100-scaled on the wire, to
          // allow decimal precision -- see _buildPaidFor's doc comment).
          SplitMode.byShares || SplitMode.byPercentage => _trimTrailingZeros(value / 100),
          _ => value.toString(),
        };
      }
    });
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
        // Shares/Percentage are both x100 on the wire (issue #34) --
        // inverse of the x100 done in _buildPaidFor, formatted back down
        // to at most 2 decimal places with no trailing zeros so "150"
        // redisplays as "1.5", not "1.50" or "150".
        SplitMode.byShares || SplitMode.byPercentage => _trimTrailingZeros(share.shares / 100),
        // Evenly's per-participant "shares" is just an equal weight with
        // no meaningful decimal value to carry over -- and, per
        // spliit-web's own expense-form.tsx, it's stored on the wire as
        // the literal integer 100 for every participant, not 1. Taking
        // that raw value here (issue #34 follow-up) meant switching this
        // *editing* expense from Evenly to Shares/Percentage showed "100"
        // in every field instead of the "1" a brand-new expense starts
        // with. Evenly's stored value isn't shown while still in Evenly
        // mode, so there's nothing to prefill -- leave the controller at
        // its constructor default ('1') instead.
        SplitMode.evenly => '1',
      };
    }

    if (e.originalAmountCents != null && e.originalCurrency != null) {
      _paidInOtherCurrency = true;
      _originalAmountController.text = (e.originalAmountCents! / 100).toStringAsFixed(2);
      _originalCurrencyController.text = e.originalCurrency!;
    }

    // No pre-population needed here for a category id this device
    // hasn't fetched a name for yet -- [_selectedCategory] synthesizes a
    // placeholder display on demand rather than requiring one to be
    // seeded into [_categories] up front.
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await widget.client.fetchCategories();
      if (!mounted || cats.isEmpty) return;
      setState(() => _categories = cats);
    } catch (_) {
      // Offline or the server's unreachable -- keep the General-only
      // fallback so the form still works without connectivity.
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

  bool get _allIncluded =>
      widget.group.participants.every((p) => _includedInSplit[p.id] ?? false);

  /// Flips every participant's included flag to the opposite of
  /// [_allIncluded] -- "Select all"/"Select none" always offers the
  /// complement of the current state (issue #29 section 2), and leaves
  /// typed values untouched so re-including someone brings their number
  /// back rather than resetting it.
  void _toggleSelectAll() {
    setState(() {
      final target = !_allIncluded;
      for (final p in widget.group.participants) {
        _includedInSplit[p.id] = target;
      }
    });
  }

  /// The typed value for [p] in the current non-evenly split mode, or
  /// null if it isn't currently a number -- every non-evenly mode takes
  /// a decimal now (issue #34), matching [_buildPaidFor]'s own parsing
  /// so the live footer/preview never disagree with what Save would
  /// actually do.
  double? _typedValue(Participant p) =>
      parseFlexibleDecimal(_splitControllers[p.id]!.text.trim());

  /// Rounded basis points (percentage x 100) for [p]'s typed value --
  /// the exact integer [_buildPaidFor] sends on the wire, and the same
  /// thing spliit-web's own expenseFormSchema sums to validate a
  /// BY_PERCENTAGE split (must total 10000). Validating in basis points
  /// rather than summing raw decimals avoids floating-point drift (e.g.
  /// three 33.33...s never quite summing to exactly 100.0).
  int? _percentageBasisPoints(Participant p) {
    final value = _typedValue(p);
    return value == null ? null : (value * 100).round();
  }

  /// Formats a decimal to at most 2 places with no trailing zeros (or
  /// trailing decimal point) -- e.g. 1.5 stays "1.5", 2.0 becomes "2",
  /// 33.3 stays "33.3". Used to redisplay a Shares/Percentage wire value
  /// (issue #34: both are x100-scaled to allow decimal precision -- see
  /// [_buildPaidFor]) and in the footer's "still to allocate" hint.
  String _trimTrailingZeros(double value) {
    var text = value.toStringAsFixed(2);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      text = text.replaceFirst(RegExp(r'\.$'), '');
    }
    return text;
  }

  /// How much of the total is still unaccounted for, in the field's own
  /// unit (percentage points, or dollars) -- null for Evenly/Shares,
  /// which have no "must sum to X" concept (issue #29 section 6 step 2).
  /// Positive means "still to allocate", negative means "over".
  double? _unallocated() {
    if (_splitMode == SplitMode.byPercentage) {
      var totalBasisPoints = 0;
      for (final p in _includedParticipants) {
        final bp = _percentageBasisPoints(p);
        if (bp == null) return null;
        totalBasisPoints += bp;
      }
      return (10000 - totalBasisPoints) / 100;
    }
    if (_splitMode == SplitMode.byAmount) {
      final amount = parseFlexibleDecimal(_amountController.text.trim());
      if (amount == null) return null;
      var total = 0.0;
      for (final p in _includedParticipants) {
        final v = _typedValue(p);
        if (v == null) return null;
        total += v;
      }
      return amount - total;
    }
    return null;
  }

  /// Ported from spliit-ios's `ExpenseFormDraft.showsShareAmounts` --
  /// issue #29 section 4. Amount mode never shows a computed preview
  /// (the typed field already *is* the amount); Percent only once the
  /// typed percentages land exactly on 100.
  bool get _showsLivePreview {
    if (_isReimbursement || _splitMode == SplitMode.byAmount) return false;
    if (_includedParticipants.isEmpty) return false;
    if (_splitMode == SplitMode.evenly) return true;
    for (final p in _includedParticipants) {
      final v = _typedValue(p);
      if (v == null || v <= 0) return false;
    }
    return _splitMode == SplitMode.byPercentage ? _unallocated() == 0 : true;
  }

  /// The live per-participant \$ amounts, computed with the same
  /// apportionment [shareCentsFor] uses at Save time, but from whatever
  /// is currently typed rather than a saved [Expense]. Null when
  /// [_showsLivePreview] is false or the amount field isn't parseable yet.
  Map<String, int>? _livePreviewAmounts() {
    if (!_showsLivePreview) return null;
    final amount = parseFlexibleDecimal(_amountController.text.trim());
    if (amount == null) return null;
    final amountCents = (amount * 100).round();
    final paidFor = _splitMode == SplitMode.evenly
        ? _includedParticipants
            .map((p) => ExpenseShare(participantId: p.id, shares: 1))
            .toList()
        : _includedParticipants
            .map((p) => ExpenseShare(
                participantId: p.id, shares: (_typedValue(p)! * 100).round()))
            .toList();
    return shareCentsFor(amountCents: amountCents, splitMode: _splitMode, paidFor: paidFor);
  }

  /// Pure validation -- no setState, no side effects -- callable from
  /// both the live footer (guarded by [_hasAttemptedSave], issue #29
  /// section 6 step 1) and [_buildPaidFor] at Save time, so the two can
  /// never disagree about what counts as a blocking problem.
  String? _splitValidationError() {
    final included = _includedParticipants;
    if (included.isEmpty) return context.l10n.expenseSelectAtLeastOne;
    if (_splitMode == SplitMode.evenly) return null;

    if (_splitMode == SplitMode.byShares) {
      for (final p in included) {
        final value = _typedValue(p);
        if (value == null || value <= 0) {
          return context.l10n.expenseEnterShares(p.name);
        }
      }
      return null;
    }

    if (_splitMode == SplitMode.byPercentage) {
      var totalBasisPoints = 0;
      for (final p in included) {
        final bp = _percentageBasisPoints(p);
        if (bp == null || bp < 0) return context.l10n.expenseEnterPercentage(p.name);
        totalBasisPoints += bp;
      }
      if (totalBasisPoints != 10000) {
        return context.l10n
            .expensePercentageMismatch(_trimTrailingZeros(totalBasisPoints / 100));
      }
      return null;
    }

    // byAmount
    final amountCents = ((parseFlexibleDecimal(_amountController.text.trim()) ?? 0) * 100).round();
    var totalCents = 0;
    for (final p in included) {
      final value = parseFlexibleDecimal(_splitControllers[p.id]!.text.trim());
      if (value == null || value < 0) return context.l10n.expenseEnterAmount(p.name);
      totalCents += (value * 100).round();
    }
    if (totalCents != amountCents) {
      final diff = ((amountCents - totalCents) / 100).toStringAsFixed(2);
      return context.l10n.expenseAmountMismatch(diff);
    }
    return null;
  }

  /// The "Paid for" section's single footer line, in the priority order
  /// from issue #29 section 6: an attempted-save blocking error first,
  /// then a running "still to allocate"/"over" hint for Percent/Amount,
  /// then the mode's static explanation.
  String _paidForFooterText() {
    if (_hasAttemptedSave) {
      final error = _splitValidationError();
      if (error != null) return error;
    }
    final unallocated = _unallocated();
    if (unallocated != null && unallocated != 0) {
      final over = unallocated < 0;
      final magnitude = unallocated.abs();
      if (_splitMode == SplitMode.byPercentage) {
        final formatted = _trimTrailingZeros(magnitude);
        return over
            ? context.l10n.expensePercentOver(formatted)
            : context.l10n.expensePercentRemaining(formatted);
      }
      final formattedAmount = magnitude.toStringAsFixed(2);
      return over
          ? context.l10n.expenseAmountOver(formattedAmount)
          : context.l10n.expenseAmountRemaining(formattedAmount);
    }
    return switch (_splitMode) {
      SplitMode.evenly => context.l10n.expenseHintEvenly,
      SplitMode.byShares => context.l10n.expenseHintShares,
      SplitMode.byPercentage => context.l10n.expenseHintPercentage,
      SplitMode.byAmount => context.l10n.expenseHintAmount,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title:
              Text(widget.isEditing ? context.l10n.expenseEditTitle : context.l10n.expenseAddTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(labelText: context.l10n.expenseTitleLabel),
                validator: (v) => (v == null || v.isEmpty) ? context.l10n.commonRequired : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountController,
                decoration:
                    InputDecoration(labelText: context.l10n.expenseAmountLabel, prefixText: '\$'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}), // amount feeds the by-amount hint below
                validator: (v) {
                  final parsed = parseFlexibleDecimal(v ?? '');
                  if (parsed == null || parsed <= 0) return context.l10n.expenseInvalidAmount;
                  return null;
                },
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: InputDecoration(labelText: context.l10n.expenseDateLabel),
                  child: Text(_formatDate(_date)),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickCategory,
                child: InputDecorator(
                  decoration: InputDecoration(labelText: context.l10n.expenseCategoryLabel),
                  child: Row(
                    children: [
                      CategoryIconGlyph(category: _selectedCategory, size: 24),
                      const SizedBox(width: 8),
                      Text(_selectedCategory.name),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _paidBy,
                decoration: InputDecoration(labelText: context.l10n.expensePaidByLabel),
                items: widget.group.participants
                    .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                    .toList(),
                onChanged: (v) => setState(() => _paidBy = v),
                validator: (v) => v == null ? context.l10n.commonRequired : null,
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _paidInOtherCurrency,
                onChanged: (v) => setState(() => _paidInOtherCurrency = v ?? false),
                title: Text(context.l10n.expensePaidInOtherCurrency),
                subtitle: Text(context.l10n.expenseGroupCurrency(widget.group.currency)),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              if (_paidInOtherCurrency) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _originalAmountController,
                        decoration:
                            InputDecoration(labelText: context.l10n.expenseOriginalAmountLabel),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        validator: (v) {
                          if (!_paidInOtherCurrency) return null;
                          final parsed = parseFlexibleDecimal(v ?? '');
                          if (parsed == null || parsed <= 0) return context.l10n.expenseInvalidAmount;
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 160,
                      child: _hasGroupCurrencyCode
                          ? InkWell(
                              onTap: _pickOriginalCurrency,
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: context.l10n.expenseCurrencyLabel,
                                  errorText: _originalCurrencyError,
                                ),
                                child: Text(
                                  _originalCurrencyController.text.isEmpty
                                      ? context.l10n.expenseCurrencySelectPlaceholder
                                      : currencyByCode(_originalCurrencyController.text).toString(),
                                ),
                              ),
                            )
                          : InputDecorator(
                              decoration: InputDecoration(
                                labelText: context.l10n.expenseCurrencyLabel,
                                helperText: context.l10n.expenseCurrencyConversionUnavailable,
                              ),
                              child: Text(widget.group.currency),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              CheckboxListTile(
                value: _isReimbursement,
                onChanged: (v) => setState(() => _isReimbursement = v ?? false),
                title: Text(context.l10n.expenseIsReimbursement),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<RecurrenceRule>(
                initialValue: _recurrenceRule,
                decoration: InputDecoration(labelText: context.l10n.expenseRepeatLabel),
                items: [
                  DropdownMenuItem(
                      value: RecurrenceRule.none, child: Text(context.l10n.expenseRepeatNone)),
                  DropdownMenuItem(
                      value: RecurrenceRule.daily, child: Text(context.l10n.expenseRepeatDaily)),
                  DropdownMenuItem(
                      value: RecurrenceRule.weekly, child: Text(context.l10n.expenseRepeatWeekly)),
                  DropdownMenuItem(
                      value: RecurrenceRule.monthly,
                      child: Text(context.l10n.expenseRepeatMonthly)),
                ],
                onChanged: (v) => setState(() => _recurrenceRule = v ?? RecurrenceRule.none),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(context.l10n.expensePaidForHeading, style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  // Always offers the opposite of the current state --
                  // issue #29 section 2 (spliit-ios: "with everyone
                  // already in the split, 'select all' has nothing left
                  // to do").
                  TextButton(
                    onPressed: _toggleSelectAll,
                    child: Text(_allIncluded
                        ? context.l10n.expenseSelectNone
                        : context.l10n.expenseSelectAll),
                  ),
                ],
              ),
              SegmentedButton<SplitMode>(
                segments: [
                  ButtonSegment(
                      value: SplitMode.evenly, label: Text(context.l10n.expenseSplitEvenly)),
                  ButtonSegment(
                      value: SplitMode.byShares, label: Text(context.l10n.expenseSplitShares)),
                  ButtonSegment(
                      value: SplitMode.byPercentage,
                      label: Text(context.l10n.expenseSplitPercent)),
                  ButtonSegment(
                      value: SplitMode.byAmount, label: Text(context.l10n.expenseSplitAmount)),
                ],
                selected: {_splitMode},
                // The selected segment is already highlighted -- with 4
                // segments crammed into the row, the extra check icon
                // pushed a label like "Percent" onto 3 lines (issue #32).
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  // Switching to Evenly removes every per-participant
                  // number field from the tree (issue #36) -- if one of
                  // them still had focus, Flutter has to send focus
                  // *somewhere* when its element is disposed, and left
                  // to its own traversal heuristics it jumped back to
                  // whichever field had focus before that (Amount or
                  // Title), which then auto-scrolled the form back up to
                  // show it. Unfocusing first (rather than letting focus
                  // land on the just-tapped SegmentedButton itself, or
                  // relying on Flutter's fallback) means no field is
                  // focused when the rebuild happens, so there's nothing
                  // to scroll to.
                  FocusScope.of(context).unfocus();
                  setState(() => _splitMode = selection.first);
                },
              ),
              const SizedBox(height: 4),
              for (final p in widget.group.participants) _paidForRow(p),
              // Hidden for a reimbursement -- a settlement is a one-off,
              // not representative of the group's normal expenses (issue
              // #29 section 7).
              if (!_isReimbursement)
                CheckboxListTile(
                  value: _saveDefaultSplittingOptions,
                  onChanged: (v) =>
                      setState(() => _saveDefaultSplittingOptions = v ?? false),
                  title: Text(context.l10n.expenseSaveDefaultSplit),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  _paidForFooterText(),
                  style: (_hasAttemptedSave && _splitValidationError() != null)
                      ? TextStyle(color: Theme.of(context).colorScheme.error)
                      : Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                decoration: InputDecoration(labelText: context.l10n.expenseNotesLabel),
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
                child: Text(_saving ? context.l10n.expenseSavingButton : context.l10n.expenseSaveButton),
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
              context.l10n.expenseDocumentsPlaceholder,
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

  /// Opens the category picker (issue #19): grouped by
  /// [Category.grouping] (matching how the server's own list is already
  /// laid out) and filterable by a type-ahead search field, rather than
  /// one long flat dropdown of 40+ categories.
  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CategoryPicker(categories: _categories, selectedId: _category),
    );
    if (picked != null) setState(() => _category = picked.id);
  }

  /// Opens the shared currency picker (issue #23) for "paid in a
  /// different currency" -- no Custom option here, since converting
  /// against a currency with no ISO code isn't possible (see
  /// [_hasGroupCurrencyCode], which gates this field being shown at
  /// all).
  Future<void> _pickOriginalCurrency() async {
    final picked = await pickCurrency(
      context,
      currencies: supportedCurrencies,
      selectedCode: _originalCurrencyController.text,
    );
    if (picked == null) return;
    setState(() {
      _originalCurrencyController.text = picked.code;
      _originalCurrencyError = null;
    });
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Widget _paidForRow(Participant p) {
    final included = _includedInSplit[p.id] ?? false;
    final preview = included ? (_livePreviewAmounts()?[p.id]) : null;
    return Row(
      children: [
        Expanded(
          child: CheckboxListTile(
            value: included,
            onChanged: (v) => setState(() => _includedInSplit[p.id] = v ?? false),
            title: Text(p.name),
            // The live \$ preview (issue #29 section 3/4) -- absent for
            // Amount (the typed field already *is* the amount) and for
            // anything that doesn't yet satisfy [_showsLivePreview].
            subtitle: preview != null ? Text('\$${(preview / 100).toStringAsFixed(2)}') : null,
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
              textAlign: TextAlign.right,
              // Recomputes the live preview/footer on every keystroke
              // (issue #29 section 6) instead of only validating at Save.
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                prefixText: _splitMode == SplitMode.byAmount ? '\$' : null,
                suffixText: switch (_splitMode) {
                  SplitMode.byShares => 'shares',
                  SplitMode.byPercentage => '%',
                  _ => null,
                },
              ),
            ),
          ),
      ],
    );
  }

  /// Builds the paidFor list for the current split mode, or returns null
  /// if [_splitValidationError] finds a problem -- the footer (via
  /// [_paidForFooterText]) is what actually surfaces that message, gated
  /// on [_hasAttemptedSave], so there's no separate error field to keep
  /// in sync here.
  /// Evenly needs no per-participant input at all -- every included
  /// participant just gets an equal weight.
  ///
  /// [SplitMode.byShares] and [SplitMode.byPercentage] both take a
  /// decimal now (issue #34) and both send [ExpenseShare.shares] as the
  /// typed value x100, rounded -- e.g. "1.5" shares -> wire 150, "33.3"%
  /// -> wire 3330. This isn't just an internal convenience: it's the
  /// exact transform spliit-web's own expenseFormSchema applies to every
  /// non-BY_AMOUNT split before submitting (confirmed against
  /// src/lib/schemas.ts and expense-form.tsx upstream) -- the same x100
  /// scaling this app already used for Percentage (see
  /// github.com/sharneng/spliit2go/issues/18 and issue #20) turns out to
  /// apply to Shares too, and is what makes decimal shares/percentages
  /// representable on the wire at all (`shares` is stored as an
  /// integer). [_prefillFrom]/[_loadDefaultSplit] divide back by 100 to
  /// redisplay an existing value. For [SplitMode.byPercentage]
  /// specifically, the basis points across all included participants
  /// must sum to exactly 10000 -- see [_percentageBasisPoints].
  List<ExpenseShare>? _buildPaidFor(int amountCents) {
    if (_splitValidationError() != null) return null;

    final included = _includedParticipants;
    return switch (_splitMode) {
      SplitMode.evenly =>
        included.map((p) => ExpenseShare(participantId: p.id, shares: 1)).toList(),
      SplitMode.byShares || SplitMode.byPercentage => included
          .map((p) => ExpenseShare(
              participantId: p.id, shares: (_typedValue(p)! * 100).round()))
          .toList(),
      SplitMode.byAmount => included
          .map((p) => ExpenseShare(
              participantId: p.id,
              shares: (parseFlexibleDecimal(_splitControllers[p.id]!.text.trim())! * 100).round()))
          .toList(),
    };
  }

  Future<void> _save() async {
    setState(() {
      _hasAttemptedSave = true;
      _saveError = null;
      _originalCurrencyError = null;
    });
    if (!_formKey.currentState!.validate()) return;
    if (_paidInOtherCurrency &&
        _hasGroupCurrencyCode &&
        _originalCurrencyController.text.trim().isEmpty) {
      setState(() => _originalCurrencyError = context.l10n.commonRequired);
      return;
    }

    final amountCents = (parseFlexibleDecimal(_amountController.text)! * 100).round();
    final paidFor = _buildPaidFor(amountCents);
    if (paidFor == null) return;

    int? originalAmountCents;
    String? originalCurrency;
    double? conversionRate;
    if (_paidInOtherCurrency) {
      final originalAmount = parseFlexibleDecimal(_originalAmountController.text.trim())!;
      originalAmountCents = (originalAmount * 100).round();
      // No code to send when the group's own currency has none to
      // convert against (see _hasGroupCurrencyCode) -- the field is
      // disabled in that case, so there's nothing the user picked.
      final code = _originalCurrencyController.text.trim().toUpperCase();
      originalCurrency = code.isEmpty ? null : code;
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

  /// Only takes effect after a save actually *succeeds* -- a split
  /// remembered from a save the server rejected would wrongly go on
  /// prefilling future expenses (issue #29 section 7). No-op for a
  /// reimbursement (the toggle is hidden for one, but this is the real
  /// gate) or when the toggle wasn't checked.
  Future<void> _rememberDefaultSplitIfRequested(List<ExpenseShare> paidFor) async {
    if (!_saveDefaultSplittingOptions || _isReimbursement) return;
    await widget.db.setDefaultSplit(
      widget.group.id,
      DefaultSplit.remembering(
        splitMode: _splitMode,
        paidFor: paidFor,
        allParticipants: widget.group.participants,
      ),
    );
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
    await _rememberDefaultSplitIfRequested(paidFor);

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
      await _rememberDefaultSplitIfRequested(paidFor);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = context.l10n.expenseEditSaveFailed(e.toString());
      });
    }
  }
}

/// The category picker's contents (issue #19): a search field followed by
/// a scrollable, grouped list. Filtering narrows to categories whose name
/// contains the query (case-insensitive); a group with no matches under
/// the current query is hidden entirely rather than shown with an empty
/// section.
class _CategoryPicker extends StatefulWidget {
  final List<Category> categories;
  final int selectedId;

  const _CategoryPicker({required this.categories, required this.selectedId});

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Groups [categories] by [Category.grouping], preserving the order
  /// groupings first appear in -- the server's own list is already laid
  /// out with each grouping's categories adjacent, so this doesn't need
  /// to re-sort, just fold consecutive runs into sections.
  List<MapEntry<String, List<Category>>> _grouped(List<Category> categories) {
    final groups = <String, List<Category>>{};
    for (final c in categories) {
      (groups[c.grouping] ??= []).add(c);
    }
    return groups.entries.toList();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.categories
        : widget.categories.where((c) => c.name.toLowerCase().contains(query)).toList();
    final sections = _grouped(filtered);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.expenseCategorySearchLabel,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: sections.isEmpty
                    ? Center(child: Text(context.l10n.expenseNoMatchingCategories))
                    : ListView(
                        children: [
                          for (final section in sections) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              child: Text(
                                section.key,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelLarge
                                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
                              ),
                            ),
                            for (final c in section.value)
                              ListTile(
                                leading: CategoryIconGlyph(category: c, size: 28),
                                title: Text(c.name),
                                trailing: c.id == widget.selectedId
                                    ? const Icon(Icons.check)
                                    : null,
                                onTap: () => Navigator.of(context).pop(c),
                              ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
