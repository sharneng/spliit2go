import 'dart:math' show ln10, log;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingController;

import '../../models/currency.dart';
import '../../models/default_split.dart';
import '../../models/expense.dart';
import '../../models/group.dart';
import '../../services/active_user.dart';
import '../../services/expense_shares.dart';
import '../../utils/decimal_input.dart';
import '../../utils/money.dart';

/// What the add/edit expense form holds and works out (#258): what's
/// typed and picked, the amounts derived from it, the conversion, the
/// shares and their validation. The screen builds the widgets, saves, and
/// does the I/O (the rate lookup, the receipt scan); this holds no
/// [BuildContext], so it's tested without building widgets.
///
/// The text fields' controllers live here, so the widgets bind to them;
/// any change to one, or to anything set through this, notifies.
class ExpenseFormModel extends ChangeNotifier {
  ExpenseFormModel({
    required this.group,
    this.existing,
    Expense? draft,
    this.activeUserId,
  }) {
    if ((existing ?? draft) case final e?) {
      _prefillFrom(e);
    } else {
      paidBy = resolveDefaultPaidBy(activeUserId: activeUserId, participants: group.participants);
    }
    for (final c in [titleController, amountController, notesController, originalAmountController, rateController,
      ...splitControllers.values]) {
      c.addListener(_typed);
    }
    for (final c in [amountController, originalAmountController, rateController]) {
      c.addListener(_amountsChanged);
    }
    markUnchanged();
  }

  final Group group;

  /// The expense being edited, if any.
  final Expense? existing;

  /// Who's using the app in this group: a new expense's payer, and
  /// "(you)" in the form.
  final String? activeUserId;

  final titleController = TextEditingController();
  final amountController = TextEditingController();
  final notesController = TextEditingController();

  /// "Amount paid", in the paid-in currency (#252).
  final originalAmountController = TextEditingController();
  final rateController = TextEditingController();

  // Per-participant values for the non-evenly modes -- shares (any
  // positive number), percentage (0-100, must sum to 100), or amount
  // (must sum to the total). Empty or 0 is "not included" (#260): only
  // Evenly has checkboxes. Filled in by switching modes ([splitMode]),
  // [_prefillFrom] or [applyDefaultSplit].
  late final Map<String, TextEditingController> splitControllers = {
    for (final p in group.participants) p.id: TextEditingController(),
  };

  late final Map<String, bool> _included = {for (final p in group.participants) p.id: true};

  String? _paidBy;
  String? get paidBy => _paidBy;
  set paidBy(String? id) => _set(() => _paidBy = id);

  DateTime _date = DateTime.now();
  DateTime get date => _date;

  /// Whether the date or category was picked (or filled from a receipt),
  /// so a scan leaves it alone (#125).
  bool _dateChosen = false;
  bool get dateChosen => _dateChosen;
  bool _categoryChosen = false;
  bool get categoryChosen => _categoryChosen;

  void setDate(DateTime date, {bool chosen = true}) => _set(() {
        _date = date;
        _dateChosen = chosen;
      });

  int _category = 0;
  int get category => _category;
  void setCategory(int id, {bool chosen = true}) => _set(() {
        _category = id;
        _categoryChosen = chosen;
      });

  bool _isSettlement = false;
  bool get isSettlement => _isSettlement;
  set isSettlement(bool value) => _set(() {
        _isSettlement = value;
        _convertedAmountInvalid = false;
      });

  bool _saveDefaultSplit = false;
  bool get saveDefaultSplit => _saveDefaultSplit;
  set saveDefaultSplit(bool value) => _set(() => _saveDefaultSplit = value);

  RecurrenceRule _recurrenceRule = RecurrenceRule.none;
  RecurrenceRule get recurrenceRule => _recurrenceRule;
  set recurrenceRule(RecurrenceRule value) => _set(() => _recurrenceRule = value);

  SplitMode _splitMode = SplitMode.evenly;
  SplitMode get splitMode => _splitMode;

  /// Switching modes keeps who's included (#260): in Shares, Percent or
  /// Amount they get equal values, 1 share, equal percentages or equal
  /// amounts, the remainder to the first, and everyone else nothing; back
  /// in Evenly, anyone with a value above 0 is checked. With no total yet,
  /// Amount's values are empty, and Evenly keeps who was checked before.
  set splitMode(SplitMode value) {
    if (value == _splitMode) return;
    final included = includedParticipants;
    if (_splitMode != SplitMode.evenly && included.isNotEmpty) {
      for (final p in group.participants) {
        _included[p.id] = included.contains(p);
      }
    }
    _splitMode = value;
    if (value != SplitMode.evenly) {
      _filling = true;
      final total = switch (value) {
        SplitMode.byPercentage => 10000,
        SplitMode.byAmount => amount,
        _ => null,
      };
      final equal = total == null || included.isEmpty
          ? null
          : shareCentsFor(
              amountCents: total,
              splitMode: SplitMode.evenly,
              paidFor: [for (final p in included) ExpenseShare(participantId: p.id, shares: 1)]);
      for (final p in group.participants) {
        final part = equal?[p.id];
        splitControllers[p.id]!.text = !included.contains(p)
            ? ''
            : switch (value) {
                SplitMode.byShares => '1',
                SplitMode.byPercentage => _localized(trimTrailingZeros(part! / 100)),
                _ => part == null ? '' : _localized(minorUnitsText(part, digits)),
              };
      }
      _filling = false;
    }
    notifyListeners();
  }

  /// [text] with the locale's decimal separator.
  String _localized(String text) => text.replaceFirst('.', _decimalSeparator);

  /// The category saved (#259): a settlement made here is a Payment,
  /// whatever was picked before it was switched to one. An edit keeps its
  /// category, hidden for a settlement, so switching there and back costs
  /// nothing.
  int get categoryToSave => existing == null && isSettlement ? paymentCategoryId : category;

  /// Spliit's "Payment" category.
  static const paymentCategoryId = 1;

  // ---------------------------------------------------------------------
  // Changes, for "Discard changes?" (#259).

  List<Object?>? _unchanged;

  /// What the user can change, as it stands. A rate filled in from the
  /// published ones isn't the user's, so only a rate of their own counts.
  List<Object?> _state() => [
        titleController.text,
        amountController.text,
        notesController.text,
        if (converting) ...[originalAmountController.text, rateIsOwn ? rateController.text : null],
        _paidIn,
        // Only what the mode uses: Evenly's checks, or the others' values.
        // Switching away and back leaves the hidden ones filled in (#266).
        for (final p in group.participants)
          _splitMode == SplitMode.evenly ? _included[p.id] : splitControllers[p.id]!.text,
        _paidBy,
        _date,
        _category,
        _isSettlement,
        _saveDefaultSplit,
        _recurrenceRule,
        _splitMode,
      ];

  /// Takes the form as it is now as where it started: once it's filled
  /// in, and shows an edit's saved rate.
  void markUnchanged() => _unchanged = _state();

  /// Whether anything differs from where the form started.
  bool get hasChanges => _unchanged != null && !listEquals(_unchanged, _state());

  /// The calculated amount (or amount to transfer) can't be saved, e.g.
  /// it rounds to zero. Set by [amountsToSave], cleared once an amount,
  /// the rate or the currency changes.
  bool _convertedAmountInvalid = false;
  bool get convertedAmountInvalid => _convertedAmountInvalid;

  void _amountsChanged() => _convertedAmountInvalid = false;

  /// Filling in several fields at once, which tells listeners once at the
  /// end rather than for each.
  bool _filling = false;

  void _typed() {
    if (!_filling) notifyListeners();
  }

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Numbers as typed.

  String _decimalSeparator = '.';

  /// The locale's decimal separator, which decides only "1,234" (#238)
  /// and is how a rate is shown. Kept here, so parsing after an await
  /// (Save) doesn't need the context. Its first setting also shows an
  /// edited expense's saved rate, which needs it.
  set decimalSeparator(String separator) {
    _decimalSeparator = separator;
    if (_savedRateToShow case final rate?) {
      _savedRateToShow = null;
      final unchanged = !hasChanges;
      rateController.text = _savedRate = rateText(rate);
      if (unchanged) markUnchanged();
    }
  }

  /// [parseFlexibleDecimal] with this locale's decimal separator.
  double? parseDecimal(String input) =>
      parseFlexibleDecimal(input, decimalSeparator: _decimalSeparator, currencies: [group.currency]);

  /// Whether [text] is an amount of at least one smallest unit once
  /// rounded to [decimalDigits] (#254 review): 0.1 yen rounds to 0, which
  /// would save a zero amount, and as an original amount an infinite rate.
  bool isPositiveAmount(String? text, int decimalDigits) {
    final parsed = parseDecimal(text ?? '');
    return parsed != null && toMinorUnits(parsed, decimalDigits) > 0;
  }

  /// [rate] as the rate field shows it: plain decimals, never an exponent,
  /// in the locale's separator, no trailing zeros.
  String rateText(double rate) {
    // 15 significant digits, all a double holds, so a saved rate shows
    // as it was saved: 14 places after the first digit.
    final exponent = rate <= 0 ? 0 : (log(rate) / ln10).floor();
    var text = rate.toStringAsFixed((14 - exponent).clamp(0, 20));
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return text.replaceAll('.', _decimalSeparator);
  }

  // ---------------------------------------------------------------------
  // Currency and conversion (#251, #252).

  /// The group currency's decimal places (#251): every amount on this
  /// form is stored in its smallest unit.
  int get digits => group.decimalDigits;

  /// Whether the group has a real ISO currency code (as opposed to a
  /// free-typed custom symbol): only then can it be converted from.
  bool get hasGroupCurrencyCode => group.currencyCode != null && group.currencyCode!.isNotEmpty;

  /// The currency the expense was paid in (#252): the group's unless
  /// another is picked, which only a group with an ISO code can do.
  late String? _paidIn = group.currencyCode;
  String? get paidIn => _paidIn;

  /// Paid in another currency than the group's (#252): "Amount paid" and
  /// "Exchange rate" show, and one amount is calculated from the other.
  bool get converting => hasGroupCurrencyCode && _paidIn != null && _paidIn != group.currencyCode;

  Currency get paidInCurrency => currencyByCode(_paidIn);

  /// The paid-in currency's decimal places.
  int get originalDigits => paidInCurrency.decimalDigits;

  /// The paid-in currency's symbol, or its code when it has none.
  String get paidInSymbol => paidInCurrency.symbol.isEmpty ? (_paidIn ?? '') : paidInCurrency.symbol;

  /// Picks the paid-in currency. A rate belongs to a pair of currencies,
  /// so it can't come along; back to the group's own currency, the
  /// calculated total is kept as the amount (spliit-ios). Returns whether
  /// anything changed, so the screen knows to look the rate up.
  bool choosePaidIn(String code) {
    if (code == _paidIn) return false;
    final converted = converting && !_isSettlement ? amount : null;
    _paidIn = code;
    _convertedAmountInvalid = false;
    _autoFilledRate = _savedRate = null;
    rateController.text = '';
    if (!converting && converted != null) amountController.text = minorUnitsText(converted, digits);
    notifyListeners();
    return true;
  }

  /// The last rate this form filled in by itself, so a rate typed over
  /// it is never overwritten by a lookup.
  String? _autoFilledRate;

  /// The rate saved with the expense being edited: the record, never
  /// looked up again by itself.
  String? _savedRate;
  double? _savedRateToShow;

  /// Counts what's typed in the rate field, so "Use the published rate"
  /// replaces only the rate it was asked to, not one typed while it was
  /// on its way.
  int _rateEdits = 0;
  int get rateEdits => _rateEdits;

  /// The user typed in the rate field.
  void rateTyped() => _rateEdits++;

  /// The rate field holds a rate of the user's: typed, or the saved one.
  bool get rateIsOwn {
    final text = rateController.text.trim();
    return text.isNotEmpty && text != _autoFilledRate;
  }

  /// That rate is the one saved with the expense being edited.
  bool get rateIsSaved => rateIsOwn && rateController.text.trim() == _savedRate;

  /// Whether a lookup may fill the rate in: always for [force] ("Use the
  /// published rate"), otherwise only into an empty or auto-filled field.
  bool wantsRate({bool force = false}) => converting && (force || !rateIsOwn);

  /// Fills in a published [rate] looked up when the field had had
  /// [editsAtRequest] edits. Anything typed since the request wins, even
  /// a rate that happens to match the one filled in before (#255
  /// review); an empty field has nothing to lose.
  void fillRate(double rate, {required bool force, required int editsAtRequest}) {
    final current = rateController.text.trim();
    if (current.isEmpty || (editsAtRequest == _rateEdits && (force || current == _autoFilledRate))) {
      _savedRate = null;
      rateController.text = _autoFilledRate = rateText(rate);
    }
  }

  /// The rate typed or filled in, if it's a number above zero.
  double? get rate {
    final rate = parseDecimal(rateController.text.trim());
    return rate != null && rate > 0 ? rate : null;
  }

  /// The amount as typed, in the group currency's smallest unit.
  int? get typedAmount => switch (parseDecimal(amountController.text.trim())) {
        final amount? => toMinorUnits(amount, digits),
        null => null,
      };

  /// "Amount paid", in the paid-in currency's smallest unit.
  int? get originalAmount => switch (parseDecimal(originalAmountController.text.trim())) {
        final amount? => toMinorUnits(amount, originalDigits),
        null => null,
      };

  /// The edited expense's own amounts (#255 review): spliit-web lets its
  /// total differ a little from the amount paid times the rate, so they
  /// stay as saved until the conversion itself is changed.
  ({int amount, int originalAmount})? _savedConversion;

  /// The conversion is the edited expense's, untouched: same currency,
  /// rate, settlement flag and the amount it was worked out from.
  bool get conversionUnchanged {
    final (saved, existing) = (_savedConversion, this.existing);
    if (saved == null || existing == null || _savedRate == null) return false;
    return _paidIn == existing.originalCurrency &&
        _isSettlement == existing.isSettlement &&
        rateController.text.trim() == _savedRate &&
        (_isSettlement ? typedAmount == saved.amount : originalAmount == saved.originalAmount);
  }

  /// The expense's amount in the group's currency: calculated from the
  /// amount paid during a conversion, so the rate always explains it;
  /// typed otherwise, and for a settlement, whose amount settled is fixed.
  int? get amount {
    if (!converting || _isSettlement) return typedAmount;
    if (conversionUnchanged) return _savedConversion!.amount;
    final (original, rate) = (originalAmount, this.rate);
    if (original == null || rate == null) return null;
    return convertToGroupAmount(
        originalAmount: original, rate: rate, originalDecimalDigits: originalDigits, decimalDigits: digits);
  }

  /// A settlement in another currency (web's direction): what to transfer
  /// in it to settle the amount.
  int? get transferAmount {
    if (conversionUnchanged) return _savedConversion!.originalAmount;
    final (amount, rate) = (typedAmount, this.rate);
    if (amount == null || rate == null) return null;
    return convertToOriginalAmount(
        amount: amount, rate: rate, decimalDigits: digits, originalDecimalDigits: originalDigits);
  }

  // ---------------------------------------------------------------------
  // Paid for.

  /// In Evenly, whether they're checked; in the other modes, whether
  /// they have a value other than 0 (#260). A value that isn't a number
  /// counts, so the split says what's wrong with it.
  bool isIncluded(String participantId) {
    if (_splitMode == SplitMode.evenly) return _included[participantId] ?? false;
    final text = splitControllers[participantId]?.text.trim() ?? '';
    return text.isNotEmpty && parseDecimal(text) != 0;
  }

  /// Checks or unchecks [participantId], in Evenly.
  void setIncluded(String participantId, bool included) => _set(() => _included[participantId] = included);

  List<Participant> get includedParticipants => group.participants.where((p) => isIncluded(p.id)).toList();

  bool get allIncluded => group.participants.every((p) => isIncluded(p.id));

  /// Flips every participant's included flag to the opposite of
  /// [allIncluded] -- "Select all"/"Select none" always offers the
  /// complement of the current state (issue #29 section 2), and leaves
  /// typed values untouched so re-including someone brings their number
  /// back rather than resetting it.
  void toggleSelectAll() => _set(() {
        final target = !allIncluded;
        for (final p in group.participants) {
          _included[p.id] = target;
        }
      });

  /// Applies this group's remembered "Paid for" split (issue #29,
  /// decisions/paid-for-split-ux-spec.md section 7), if it still applies
  /// to the group's current participants.
  void applyDefaultSplit(DefaultSplit split) {
    if (!split.appliesTo(group.participants)) return;
    // It arrives after the form opens: what it fills in is where the
    // form starts, not a change of the user's.
    final unchanged = !hasChanges;
    _splitMode = split.splitMode;
    if (split.shares case final shares?) {
      for (final p in group.participants) {
        final value = shares[p.id];
        _included[p.id] = value != null;
        splitControllers[p.id]!.text = value == null
            ? ''
            : switch (split.splitMode) {
                // Inverse of the x100 done in [paidFor] -- issue #34: both
                // are x100-scaled on the wire, to allow decimal precision.
                SplitMode.byShares || SplitMode.byPercentage => _localized(trimTrailingZeros(value / 100)),
                _ => value.toString(),
              };
      }
    }
    if (unchanged) markUnchanged();
    notifyListeners();
  }

  /// The typed value for [p] in the current non-evenly split mode, or
  /// null if it isn't currently a number -- every non-evenly mode takes
  /// a decimal (issue #34), matching [paidFor]'s own parsing so the live
  /// footer/preview never disagree with what Save would actually do.
  double? typedValue(Participant p) => parseDecimal(splitControllers[p.id]!.text.trim());

  /// Rounded basis points (percentage x 100) for [p]'s typed value -- the
  /// exact integer [paidFor] sends on the wire, and the same thing
  /// spliit-web's own expenseFormSchema sums to validate a BY_PERCENTAGE
  /// split (must total 10000). Validating in basis points rather than
  /// summing raw decimals avoids floating-point drift (e.g. three
  /// 33.33...s never quite summing to exactly 100.0).
  int? percentageBasisPoints(Participant p) {
    final value = typedValue(p);
    return value == null ? null : (value * 100).round();
  }

  /// How much of the total is still unaccounted for, in the field's own
  /// unit (percentage points, or major units of money) -- null for
  /// Evenly/Shares, which have no "must sum to X" concept (issue #29
  /// section 6 step 2). Positive means "still to allocate", negative
  /// means "over".
  double? unallocated() {
    if (_splitMode == SplitMode.byPercentage) {
      var totalBasisPoints = 0;
      for (final p in includedParticipants) {
        final bp = percentageBasisPoints(p);
        if (bp == null) return null;
        totalBasisPoints += bp;
      }
      return (10000 - totalBasisPoints) / 100;
    }
    if (_splitMode == SplitMode.byAmount) {
      final amountMinor = amount;
      if (amountMinor == null) return null;
      var total = 0.0;
      for (final p in includedParticipants) {
        final v = typedValue(p);
        if (v == null) return null;
        total += v;
      }
      return fromMinorUnits(amountMinor, digits) - total;
    }
    return null;
  }

  /// Ported from spliit-ios's `ExpenseFormDraft.showsShareAmounts` --
  /// issue #29 section 4. Amount mode never shows a computed preview
  /// (the typed field already *is* the amount); Percent only once the
  /// typed percentages land exactly on 100.
  bool get showsLivePreview {
    if (_isSettlement || _splitMode == SplitMode.byAmount) return false;
    if (includedParticipants.isEmpty) return false;
    if (_splitMode == SplitMode.evenly) return true;
    for (final p in includedParticipants) {
      final v = typedValue(p);
      if (v == null || v <= 0) return false;
    }
    return _splitMode == SplitMode.byPercentage ? unallocated() == 0 : true;
  }

  /// The live per-participant amounts, computed with the same
  /// apportionment [shareCentsFor] uses at Save time, but from whatever
  /// is currently typed rather than a saved [Expense]. Null when
  /// [showsLivePreview] is false or the amount isn't known yet.
  Map<String, int>? livePreviewAmounts() {
    if (!showsLivePreview) return null;
    final amountMinor = amount;
    if (amountMinor == null) return null;
    final paidFor = _splitMode == SplitMode.evenly
        ? [for (final p in includedParticipants) ExpenseShare(participantId: p.id, shares: 1)]
        : [
            for (final p in includedParticipants)
              ExpenseShare(participantId: p.id, shares: (typedValue(p)! * 100).round()),
          ];
    return shareCentsFor(amountCents: amountMinor, splitMode: _splitMode, paidFor: paidFor);
  }

  /// What's wrong with the split, if anything -- pure, so the live footer
  /// (once Save was tried, issue #29 section 6 step 1) and [paidFor] at
  /// Save time can never disagree about what counts as a blocking problem.
  SplitProblem? splitProblem() {
    final included = includedParticipants;
    if (included.isEmpty) return const NoOneIncluded();
    switch (_splitMode) {
      case SplitMode.evenly:
        return null;
      case SplitMode.byShares:
        for (final p in included) {
          final value = typedValue(p);
          if (value == null || value <= 0) return InvalidValue(p);
        }
        return null;
      case SplitMode.byPercentage:
        var totalBasisPoints = 0;
        for (final p in included) {
          final bp = percentageBasisPoints(p);
          if (bp == null || bp < 0) return InvalidValue(p);
          totalBasisPoints += bp;
        }
        return totalBasisPoints == 10000 ? null : PercentagesDontAddUp(totalBasisPoints);
      case SplitMode.byAmount:
        final amountMinor = amount ?? 0;
        var total = 0;
        for (final p in included) {
          final value = typedValue(p);
          if (value == null || value < 0) return InvalidValue(p);
          total += toMinorUnits(value, digits);
        }
        return total == amountMinor ? null : AmountsDontAddUp(amountMinor - total);
    }
  }

  /// The paidFor list for the current split mode, or null if
  /// [splitProblem] finds a problem. Evenly needs no per-participant
  /// input at all -- every included participant just gets an equal
  /// weight.
  ///
  /// [SplitMode.byShares] and [SplitMode.byPercentage] both take a decimal
  /// (issue #34) and both send [ExpenseShare.shares] as the typed value
  /// x100, rounded -- e.g. "1.5" shares -> wire 150, "33.3"% -> wire
  /// 3330. That's the exact transform spliit-web's own expenseFormSchema
  /// applies to every non-BY_AMOUNT split before submitting (src/lib/
  /// schemas.ts and expense-form.tsx upstream), and what makes decimal
  /// shares/percentages representable on the wire at all (`shares` is
  /// stored as an integer). [_prefillFrom]/[applyDefaultSplit] divide
  /// back by 100 to redisplay an existing value.
  List<ExpenseShare>? paidFor() {
    if (splitProblem() != null) return null;
    final included = includedParticipants;
    return switch (_splitMode) {
      SplitMode.evenly => [for (final p in included) ExpenseShare(participantId: p.id, shares: 1)],
      SplitMode.byShares || SplitMode.byPercentage => [
          for (final p in included) ExpenseShare(participantId: p.id, shares: (typedValue(p)! * 100).round()),
        ],
      SplitMode.byAmount => [
          for (final p in included) ExpenseShare(participantId: p.id, shares: toMinorUnits(typedValue(p)!, digits)),
        ],
    };
  }

  // ---------------------------------------------------------------------
  // Saving.

  /// The amounts to save, or null when a conversion's calculated amount
  /// (or amount to transfer) can't be saved, which [convertedAmountInvalid]
  /// then says. A conversion's amounts are in each currency's own smallest
  /// unit (#251), related by the rate (#252): the amount is calculated
  /// from the amount paid, or for a settlement the amount to transfer
  /// from the amount settled. Either can round to nothing. Call once the
  /// fields have validated.
  ExpenseAmounts? amountsToSave() {
    if (!converting) return ExpenseAmounts(amount: amount!);
    final original = _isSettlement ? transferAmount : originalAmount;
    final total = amount;
    if (original == null || original <= 0 || total == null || total <= 0) {
      _set(() => _convertedAmountInvalid = true);
      return null;
    }
    return ExpenseAmounts(amount: total, originalAmount: original, originalCurrency: _paidIn, conversionRate: rate);
  }

  // ---------------------------------------------------------------------

  /// Fills everything from [e] -- edit and draft mode's starting point.
  /// Runs once; the form doesn't re-sync with a changing expense.
  void _prefillFrom(Expense e) {
    titleController.text = e.title;
    amountController.text = minorUnitsText(e.amountCents, digits);
    notesController.text = e.notes;
    _paidBy = e.paidBy;
    _category = e.category;
    _date = e.date;
    _isSettlement = e.isSettlement;
    _recurrenceRule = e.recurrenceRule;
    _splitMode = e.splitMode;

    // Whoever isn't in it has no value: not included (#260).
    for (final p in group.participants) {
      _included[p.id] = false;
    }
    for (final share in e.paidFor) {
      _included[share.participantId] = true;
      final controller = splitControllers[share.participantId];
      if (controller == null) continue;
      controller.text = switch (e.splitMode) {
        SplitMode.byAmount => minorUnitsText(share.shares, digits),
        // Shares/Percentage are both x100 on the wire (issue #34) --
        // inverse of the x100 done in [paidFor], formatted back down to
        // at most 2 decimal places with no trailing zeros so "150"
        // redisplays as "1.5", not "1.50" or "150".
        SplitMode.byShares || SplitMode.byPercentage => trimTrailingZeros(share.shares / 100),
        // Evenly's per-participant "shares" is just an equal weight,
        // stored by spliit-web as 100 for everyone, not 1 (issue #34
        // follow-up): switching an edited expense from Evenly to Shares
        // should show the "1" a new expense starts with, not "100".
        SplitMode.evenly => '1',
      };
    }

    // Only originalCurrency says "converted": the server keeps the old
    // amount and rate of a conversion that was removed (#252).
    if (e.originalCurrency != null && hasGroupCurrencyCode) {
      _paidIn = e.originalCurrency;
      if (e.originalAmountCents case final original?) {
        originalAmountController.text = minorUnitsText(original, originalDigits);
        // Not for a draft: it's a new expense, worked out afresh.
        if (identical(e, existing)) _savedConversion = (amount: e.amountCents, originalAmount: original);
      }
      // Shown in the locale's own decimals, once [decimalSeparator] is set.
      _savedRateToShow = e.conversionRate;
    }
  }

  @override
  void dispose() {
    for (final c in [titleController, amountController, notesController, originalAmountController, rateController,
      ...splitControllers.values]) {
      c.dispose();
    }
    super.dispose();
  }
}

/// What [ExpenseFormModel.amountsToSave] found to save.
@immutable
class ExpenseAmounts {
  const ExpenseAmounts({required this.amount, this.originalAmount, this.originalCurrency, this.conversionRate});

  /// In the group currency's smallest unit.
  final int amount;

  /// In the paid-in currency's smallest unit; all three null together
  /// without a conversion.
  final int? originalAmount;
  final String? originalCurrency;
  final double? conversionRate;
}

/// Why a split can't be saved; the screen says it in words.
sealed class SplitProblem {
  const SplitProblem();
}

/// Nobody is in the split.
class NoOneIncluded extends SplitProblem {
  const NoOneIncluded();
}

/// [participant]'s share, percentage or amount isn't a valid number.
class InvalidValue extends SplitProblem {
  const InvalidValue(this.participant);
  final Participant participant;
}

/// The percentages come to [totalBasisPoints] / 100 %, not 100 %.
class PercentagesDontAddUp extends SplitProblem {
  const PercentagesDontAddUp(this.totalBasisPoints);
  final int totalBasisPoints;
}

/// The amounts miss the total by [difference] (positive: short of it),
/// in the group currency's smallest unit.
class AmountsDontAddUp extends SplitProblem {
  const AmountsDontAddUp(this.difference);
  final int difference;
}

/// Formats a decimal to at most 2 places with no trailing zeros (or
/// trailing decimal point) -- e.g. 1.5 stays "1.5", 2.0 becomes "2", 33.3
/// stays "33.3". Used to redisplay a Shares/Percentage wire value and in
/// the footer's "still to allocate" hint.
String trimTrailingZeros(double value) {
  var text = value.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}
