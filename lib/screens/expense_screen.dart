import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show TargetPlatform, Uint8List, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:uuid/uuid.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../services/exchange_rates.dart';
import 'expense_form/expense_form_model.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../models/default_split.dart';
import '../l10n/category_names.dart';
import '../l10n/context_l10n.dart';
import '../services/active_user.dart';
import '../services/category_store.dart';
import '../sync/outbox.dart';
import '../utils/date_format.dart';
import '../widgets/currency_picker.dart';
import '../widgets/category_icon.dart';
import '../widgets/error_message.dart';
import '../services/error_reporting.dart';
import '../services/receipt_cache.dart';
import '../services/receipt_fill.dart';
import '../services/receipt_photo.dart';
import '../services/receipt_scanner.dart';
import '../services/receipt_text.dart';
import '../services/settings_service.dart';
import '../widgets/receipt_attachments.dart';
import '../widgets/receipt_language.dart';
import '../theme.dart';
import '../utils/haptics.dart';
import '../widgets/app_menu.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/grouped_section.dart';
import '../widgets/top_bar_buttons.dart';
import 'expense_form/currency_card.dart';
import 'expense_form/receipt_scan_card.dart';
import 'expense_form/split_card.dart';
import '../widgets/expense_list.dart' show participantColors;
import '../widgets/group_monogram.dart';
import '../widgets/participant_sheet.dart';

/// Adds -- or, given [existingExpense], edits -- an expense. An expense
/// with [Expense.isSettlement] set is a settlement/"paid back"
/// entry -- same fields, same screen, no special-casing needed here.
/// (balances_screen.dart's own "mark as paid" writes a pending
/// settlement expense directly rather than opening this screen, but
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
/// in" a different currency, settlement flag, save-as-default-split,
/// recurrence, notes, and receipts (#123): photos are uploaded as they're
/// added, so they're documents by the time the expense is saved; see
/// [ReceiptAttachmentsController] for what happens to one that isn't
/// uploaded.
///
/// A new expense can be filled in from a receipt (#125, Android): Scan
/// receipt reads it on the phone, keeps the photo with the expense, and
/// fills in only what the user hasn't; see [receiptFill]. The receipt's
/// language is picked beside it (#153).
class ExpenseScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final Group group;
  /// This device's saved "active user" (see SettingsService), if any --
  /// a new expense's "Paid by" via [resolveDefaultPaidBy] (an edit's
  /// comes from the expense itself), and "(you)" and the emerald
  /// monogram in the form (#260). Passed in rather than loaded here so
  /// this screen doesn't need SharedPreferences of its own to test.
  final String? activeUserId;

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

  /// Where receipt photos come from (#123); a fake in widget tests.
  final ReceiptPhotoPicker receiptPicker;

  /// Prepares a picked photo for upload; see [prepareReceiptPhoto].
  @visibleForTesting
  final Future<PreparedReceipt> Function(Uint8List)? prepareReceipt;

  /// Reads receipts on the phone (#125); a fake in widget tests.
  final ReceiptScanner receiptScanner;

  /// Opens this app's page in the phone's Settings, offered when the
  /// camera or photo library is off for it; [openAppSettings] on the
  /// iPhone when null, and nothing on Android, where image_picker uses
  /// other apps and doesn't ask.
  @visibleForTesting
  final Future<bool> Function()? openSettings;

  /// Where the receipt language picked in each group is remembered
  /// (#153); [SettingsService] when null.
  final SettingsService? settings;

  const ExpenseScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.activeUserId,
    this.existingExpense,
    this.initialDraft,
    this.receiptPicker = const ImagePickerReceiptPhotoPicker(),
    this.prepareReceipt,
    this.receiptScanner = const PlatformReceiptScanner(),
    this.settings,
    this.openSettings,
  });

  bool get isEditing => existingExpense != null;

  @override
  State<ExpenseScreen> createState() => _ExpenseScreenState();
}

class _ExpenseScreenState extends State<ExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scroll = ScrollController();

  /// What a refused save scrolls to, besides the fields (#259): the split's
  /// footer, and a calculated amount that can't be saved.
  final _paidForFooterKey = GlobalKey();
  final _calculatedKey = GlobalKey();

  /// What's typed and picked, and what it works out to (#258).
  late final _m = ExpenseFormModel(
    group: widget.group,
    existing: widget.existingExpense,
    draft: widget.initialDraft,
    activeUserId: widget.activeUserId,
  );
  bool _saving = false;

  /// The receipts in this form (#123).
  late final _receipts = ReceiptAttachmentsController(
    client: widget.client,
    cache: ReceiptCache.of(widget.db),
    groupId: widget.group.id,
    existing: widget.existingExpense?.documents ?? const [],
    prepare: widget.prepareReceipt,
  );
  String? _saveError;
  String? _saveErrorDiagnostics;

  /// True once Save has been pressed at least once -- gates whether the
  /// "Paid for" footer shows a blocking validation error or the running
  /// "still to allocate" hint (issue #29, decisions/paid-for-split-ux-spec.md
  /// section 6): a fresh form shouldn't greet the user with red text
  /// before they've done anything.
  bool _hasAttemptedSave = false;

  _Scan _scan = _Scan.idle;
  String? _scanDiagnostics;

  /// What the last scan left beside the fields it didn't fill.
  ReceiptFill? _scanFill;

  /// The receipt language (#153): the one picked in this group last, or
  /// else the phone's language when its model is there, or else Latin.
  ReceiptScript _receiptScript = ReceiptScript.latin;

  /// The languages whose models are on the phone, as Play services last
  /// said.
  Set<ReceiptScript> _receiptScripts = {ReceiptScript.latin};

  /// The photo the last scan read, so picking another language reads it
  /// again rather than asking for a new one (#153).
  PreparedReceipt? _scannedPhoto;

  /// What that reading put in the form, which reading it again in another
  /// language replaces, where the user hasn't changed it.
  _ScanFilled? _scanFilled;

  /// The language the last scan found missing, for its message.
  ReceiptScript? _missingScript;

  _RateState _rateState = _RateState.idle;
  ExchangeRate? _foundRate;

  /// Which lookup is current: an answer to an older one is ignored.
  int _rateLookups = 0;

  // The server's list as last read, or Spliit's seeded one until this
  // device has read it: offline, the picker still has every category
  // (#132).
  List<Category> _categories = spliitSeedCategories;

  /// The fetched [Category] for the form's category, or null if it isn't in
  /// [_categories] (yet, or ever). Its display name is translated at
  /// presentation time via [localizedCategoryLabel]; the model's own
  /// English `name`/`grouping` stay untouched, since the icon lookup keys
  /// on them.
  Category? get _knownCategory {
    for (final c in _categories) {
      if (c.id == _m.category) return c;
    }
    return null;
  }

  /// The currently-selected category, falling back to a synthesized
  /// placeholder if the form's category isn't (yet, or ever) in [_categories] --
  /// keeps the picker's "current selection" display never crashing on a
  /// category id this device hasn't fetched a name for.
  Category get _selectedCategory => _categories.firstWhere(
        (c) => c.id == _m.category,
        orElse: () => Category(id: _m.category, name: 'Category $_m.category', grouping: 'Other'),
      );

  @override
  void initState() {
    super.initState();
    // Every change to the form shows: the amounts, previews and footer
    // are worked out from it.
    _m.addListener(_changed);
    // A conversion opened without a rate gets one (#252); a saved rate is
    // the record and stays, with the published one quoted under it (#261).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_m.converting) return;
      unawaited(_loadRateOrder());
      unawaited(_lookUpRate());
    });
    // The model pre-fills an edit or a draft the same way: a draft only
    // differs in _save() (new id, normal add path), not in what's shown.
    if (widget.existingExpense == null && widget.initialDraft == null) {
      // Only for a plain brand-new expense -- not for edit (the model
      // above already set the real split) and not for a draft like
      // balances_screen's "mark as paid" (its settlement split is the
      // whole point of that flow and shouldn't be overridden by a
      // remembered default -- isSplitWorthRemembering excludes
      // settlements for the same reason on the write side).
      _loadDefaultSplit();
    }
    _loadCategories();
    if (_offersScan) _loadReceiptLanguage();
  }

  SettingsService get _settings => widget.settings ?? SettingsService();

  /// Best effort: without an answer from Play services, the picker offers
  /// Latin and asks again when it opens.
  Future<void> _loadReceiptLanguage() async {
    final phone = ReceiptScript.forLanguage(WidgetsBinding.instance.platformDispatcher.locale.languageCode);
    var installed = _receiptScripts;
    ReceiptScript? picked;
    try {
      installed = await widget.receiptScanner.installedScripts();
    } catch (e, st) {
      if (!isMissingPlugin(e)) ErrorReporter.instance.report(e, st, operation: 'Listing receipt languages');
    }
    try {
      picked = ReceiptScript.values.asNameMap()[await _settings.receiptScript(widget.group.id)];
    } catch (e, st) {
      if (!isMissingPlugin(e)) ErrorReporter.instance.report(e, st, operation: 'Loading the receipt language');
    }
    if (!mounted) return;
    setState(() {
      _receiptScripts = installed;
      _receiptScript = [picked, phone].nonNulls.where(installed.contains).firstOrNull ?? ReceiptScript.latin;
    });
  }

  /// The receipt language picker (#153). Picking another language after a
  /// scan reads that scan's photo again.
  Future<void> _pickReceiptLanguage() async {
    _dropFocus();
    final picked = await showReceiptLanguagePicker(
      context,
      scanner: widget.receiptScanner,
      selected: _receiptScript,
      installed: _receiptScripts,
      onInstalledChanged: (installed) {
        if (!mounted) return;
        setState(() {
          _receiptScripts = installed;
          if (!installed.contains(_receiptScript)) _receiptScript = ReceiptScript.latin;
        });
      },
    );
    if (picked == null || !mounted) return;
    final changed = picked != _receiptScript;
    setState(() => _receiptScript = picked);
    try {
      await _settings.setReceiptScript(widget.group.id, picked.name);
    } catch (e, st) {
      // Only the remembering failed; this form still uses it.
      if (!isMissingPlugin(e)) ErrorReporter.instance.report(e, st, operation: 'Saving the receipt language');
    }
    if (changed && _scannedPhoto != null && _scan != _Scan.reading && mounted) {
      await _readReceipt(_scannedPhoto!, again: true);
    }
  }

  /// Takes back what the last reading filled in, where the user hasn't
  /// changed it since, before the same photo is read in another language.
  void _undoScanFill() {
    final filled = _scanFilled;
    if (filled == null) return;
    if (filled.title != null && _m.titleController.text == filled.title) _m.titleController.text = '';
    if (filled.amountField case final field? when field.text == filled.amount) field.text = '';
    if (filled.date case (final date, final before)? when _m.date == date) {
      _m.setDate(before, chosen: false);
    }
    if (filled.category case (final id, final before)? when _m.category == id) {
      _m.setCategory(before, chosen: false);
    }
    _scanFilled = null;
  }

  /// What's on this device, then the server's list if it's read now.
  /// Read, not watched: the form is short-lived.
  Future<void> _loadCategories() async {
    final store = CategoryStore.of(widget.db);
    Future<void> show() async {
      final cats = await store.current(widget.client);
      if (mounted) setState(() => _categories = cats);
    }

    await show();
    await store.refresh(widget.client);
    await show();
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
    if (!mounted || split == null) return;
    _m.applyDefaultSplit(split);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _m.removeListener(_changed);
    _m.dispose();
    _receipts.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _addReceipt(ReceiptSource source) async {
    try {
      final photo = await widget.receiptPicker.pick(source);
      if (photo == null || !mounted) return;
      await _receipts.add(photo);
    } catch (e, st) {
      _photoFailed(e, st);
    }
  }

  /// The picker or an unreadable photo; upload failures stay on the
  /// photo instead. A missing camera (a simulator) lands here too. The
  /// camera or library being off for the app is explained, with a way to
  /// Settings, rather than reported.
  void _photoFailed(Object e, StackTrace st) {
    if (e is ReceiptAccessOff) {
      if (mounted) {
        unawaited(showReceiptAccessOff(context, e.source,
            openSettings: widget.openSettings ?? (defaultTargetPlatform == TargetPlatform.iOS ? openAppSettings : null)));
      }
      return;
    }
    final error = ErrorReporter.instance.report(e, st, operation: 'Adding a receipt photo');
    if (mounted) {
      showErrorSnackBar(context, context.l10n.expenseReceiptPhotoFailed, diagnostics: error.diagnostics);
    }
  }

  /// Offered for a new expense on a phone that reads receipts (#125). A
  /// draft (Balances' "mark as paid") is already filled in.
  bool get _offersScan => !widget.isEditing && widget.initialDraft == null && widget.receiptScanner.isSupported;

  /// Scan receipt (#125): the Document Scanner, or the camera and library
  /// when it can't run. On the iPhone, whose document camera can't import
  /// a photo, camera or library is asked first, and the camera is the
  /// document camera (#155). The photo joins the receipts like any other,
  /// and is read as soon as it's prepared, while it uploads.
  Future<void> _scanReceipt() async {
    _dropFocus();
    try {
      final scanner = widget.receiptScanner;
      ReceiptSource? asked;
      if (!scanner.scannerImportsPhotos) {
        asked = await chooseReceiptSource(context);
        if (asked == null || !mounted) return;
      }
      Uint8List? photo;
      if (asked == ReceiptSource.library) {
        photo = await widget.receiptPicker.pick(ReceiptSource.library);
      } else {
        try {
          photo = await scanner.scanDocument();
        } on ReceiptScannerUnavailable {
          if (!mounted) return;
          final source = asked ?? await chooseReceiptSource(context);
          if (source == null) return;
          photo = await widget.receiptPicker.pick(source);
        }
      }
      if (photo == null || !mounted) return;
      await _receipts.add(photo, onPrepared: _readReceipt);
    } catch (e, st) {
      _photoFailed(e, st);
    }
  }

  /// Reads [photo] in the picked language and fills the form. [again]:
  /// the same photo in another language, which replaces what the last
  /// reading filled in.
  Future<void> _readReceipt(PreparedReceipt photo, {bool again = false}) async {
    final script = _receiptScript;
    setState(() {
      if (again) _undoScanFill();
      _scannedPhoto = photo;
      _scanFilled = null;
      _scan = _Scan.reading;
      _scanFill = null;
      _scanDiagnostics = null;
    });
    try {
      final blocks = await widget.receiptScanner.recognizeText(photo.bytes, script: script);
      final scan = readReceipt(receiptRows(blocks), categories: _categories, today: DateTime.now());
      if (!mounted) return;
      // The form as it is now, not as it was when the scan started: the
      // user may have typed meanwhile. During a conversion the total is
      // what was paid, in the currency it was paid in (#252).
      final paidIn = _m.converting && !_m.isSettlement;
      final amountField = paidIn ? _m.originalAmountController : _m.amountController;
      final fill = receiptFill(
        scan,
        ReceiptFormState(
          titleEmpty: _m.titleController.text.trim().isEmpty,
          amountEmpty: amountField.text.trim().isEmpty,
          dateChosen: _m.dateChosen,
          categoryChosen: _m.categoryChosen,
          currencyCode: paidIn ? _m.paidIn : widget.group.currencyCode,
          currencySymbol: paidIn ? _m.paidInSymbol : widget.group.currency,
        ),
      );
      final dateBefore = _m.date;
      setState(() {
        final filled = _ScanFilled();
        if (fill.title case final title?) _m.titleController.text = filled.title = title;
        if (fill.amountCents case final cents?) {
          // A receipt total is read in hundredths whatever the currency.
          amountField.text = filled.amount = (cents / 100).toStringAsFixed(paidIn ? _m.originalDigits : _m.digits);
          filled.amountField = amountField;
        }
        if (fill.date case final date?) {
          filled.date = (date, _m.date);
          _m.setDate(date);
        }
        if (fill.categoryId case final id?) {
          filled.category = (id, _m.category);
          _m.setCategory(id);
        }
        _scanFilled = filled;
        _scanFill = fill;
        _scan = scan.isEmpty
            ? _Scan.nothing
            : fill.filledAny
                ? _Scan.filled
                : _Scan.hintsOnly;
      });
      // The receipt's day has its own rate (#252).
      if (_m.date != dateBefore) unawaited(_lookUpRate());
    } on ReceiptTextModelMissing catch (e) {
      // Removed, or Play services' data was cleared, since the form
      // opened: the picker offers it for download again.
      if (!mounted) return;
      setState(() {
        _scan = _Scan.modelMissing;
        _missingScript = e.script;
        _receiptScripts = {..._receiptScripts}..remove(e.script);
      });
    } catch (e, st) {
      final error = ErrorReporter.instance.report(e, st, operation: 'Reading a receipt');
      if (mounted) {
        setState(() {
          _scan = _Scan.failed;
          _scanDiagnostics = error.diagnostics;
        });
      }
    }
  }

  /// "Receipt: …" under a field, for what the scan didn't fill in.
  String? _scanHint(String? value) => value == null ? null : context.l10n.expenseScanHint(value);

  Widget _scanSection(BuildContext context) {
    final l10n = context.l10n;
    return ReceiptScanCard(
      status: switch (_scan) {
        _Scan.idle => l10n.expenseScanIntro,
        _Scan.reading => l10n.expenseScanReading,
        _Scan.filled => l10n.expenseScanFilled,
        _Scan.hintsOnly => '${l10n.expenseScanHintsOnly} ${l10n.expenseScanTryLanguage}',
        _Scan.nothing => '${l10n.expenseScanNothing} ${l10n.expenseScanTryLanguage}',
        _Scan.failed => l10n.expenseScanFailed,
        _Scan.modelMissing => l10n.expenseScanModelMissing(receiptScriptName(context, _missingScript!)),
      },
      reading: _scan == _Scan.reading,
      failed: _scan == _Scan.failed,
      diagnostics: _scanDiagnostics,
      language: receiptScriptShortName(_receiptScript),
      onScan: _scanReceipt,
      onPickLanguage: _pickReceiptLanguage,
    );
  }

  /// Whether closing loses anything (#259): a change to the form, or to
  /// its receipts.
  bool get _hasChanges =>
      _m.hasChanges ||
      _receipts.hasNew ||
      _receipts.kept.length != (widget.existingExpense?.documents.length ?? 0);

  /// Closing with changes asks first (#259); photos added here, which
  /// nothing else keeps, are named (#123).
  Future<void> _confirmLeave() async {
    final l10n = context.l10n;
    final discard = await showAdaptiveDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog.adaptive(
        title: Text(l10n.expenseDiscardChangesTitle),
        content: _receipts.hasNew ? Text(l10n.expenseReceiptsDiscardBody) : null,
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false), child: Text(l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
              child: Text(l10n.expenseReceiptsDiscard)),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _m.decimalSeparator =
        NumberFormat.decimalPattern(Localizations.localeOf(context).toString()).symbols.DECIMAL_SEP;
  }

  /// Asks for the rate of the paid-in currency on the expense's day. It's
  /// filled in only into an empty or auto-filled field, or always for
  /// [force] ("Use the published rate"); otherwise the footer quotes it.
  Future<void> _lookUpRate({bool force = false}) async {
    final lookup = ++_rateLookups;
    final edits = _m.rateEdits;
    final from = _m.paidIn, to = widget.group.currencyCode;
    if (!_m.converting || from == null || to == null) {
      setState(() => _rateState = _RateState.idle);
      return;
    }
    // Looked up even for a rate of the user's: the footer quotes the
    // published one (#261), which fillRate puts only where it may.
    setState(() => _rateState = _RateState.loading);
    _RateState state;
    ExchangeRate? found;
    try {
      found = await ExchangeRates.of(widget.db).rate(_m.date, from, to, force: force);
      state = _RateState.found;
    } on NoPublishedRate {
      state = _RateState.noRate;
    } on RatesUnavailable {
      state = _RateState.unavailable;
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Looking up the $from to $to rate');
      state = _RateState.unavailable;
    }
    // An answer to a question the form isn't asking any more.
    if (!mounted || lookup != _rateLookups) return;
    setState(() {
      _rateState = state;
      _foundRate = found;
    });
    if (found != null) _m.fillRate(found.rate, force: force, editsAtRequest: edits);
  }

  /// Where the rate in the field comes from, under it.
  String _rateStatus(BuildContext context) {
    final l10n = context.l10n;
    final own = _m.rateIsSaved ? l10n.expenseRateSaved : l10n.expenseRateTyped;
    final found = _foundRate;
    final status = switch (_rateState) {
      _RateState.found when found != null => () {
          final day = formatDate(found.publishedOn, locale: context.appLocale);
          final published = found.offline
              ? l10n.expenseRatePublishedOffline(_m.ratePair, _m.shownRateText(found.rate), day)
              : l10n.expenseRatePublished(_m.ratePair, _m.shownRateText(found.rate), day);
          // The footer is for reference (#261): it says when the field is
          // another rate.
          return _m.rateIsOwn && !_m.showsRate(found.rate) ? '$published $own' : published;
        }(),
      _ when _m.rateIsOwn => own,
      _RateState.noRate => l10n.expenseRateNone,
      _RateState.unavailable => l10n.expenseRateUnavailable,
      _ => l10n.expenseRateLoading,
    };
    return status;
  }

  /// "Use the published rate": when the field isn't it, or to try again.
  bool get _canRefreshRate => switch (_rateState) {
        _RateState.loading || _RateState.idle => false,
        _RateState.found => switch (_foundRate) {
            final found? => found.offline || !_m.showsRate(found.rate),
            null => false,
          },
        _RateState.noRate || _RateState.unavailable => true,
      };

  /// A tap on the pair (#261): the other currency first, remembered on
  /// this device for the pair.
  void _swapRate() {
    _rateSwaps++;
    _m.swapRatePair();
    final (paidIn, own, first) = (_m.paidIn, widget.group.currencyCode, _m.rateBaseCode);
    if (paidIn == null || own == null || first == null) return;
    unawaited(_settings.setRateBase(paidIn, own, first).catchError((Object e, StackTrace st) {
      ErrorReporter.instance.report(e, st, operation: 'Saving the exchange rate order');
    }));
  }

  /// Which currency of the pair the rate is written with first (#261):
  /// the one this device swapped to, otherwise the more valuable by the
  /// newest saved rates.
  Future<void> _loadRateOrder() async {
    final (paidIn, own, swaps) = (_m.paidIn, widget.group.currencyCode, _rateSwaps);
    if (!_m.converting || paidIn == null || own == null) return;
    final ranking = await ExchangeRates.of(widget.db).ranking();
    String? base;
    try {
      base = await _settings.rateBase(paidIn, own);
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Reading the exchange rate order');
    }
    if (!mounted || _m.paidIn != paidIn) return;
    _m.ranking = ranking;
    // A swap made while this was being read is newer (#270 review).
    if (_rateSwaps == swaps) _m.rateBase = base;
  }

  /// Taps on the pair, so a saved order read since doesn't undo one.
  int _rateSwaps = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _receipts,
      builder: (context, child) => PopScope(
        canPop: !_hasChanges,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _confirmLeave();
        },
        child: child!,
      ),
      child: _form(context),
    );
  }

  /// The title says what's being added or edited (#259).
  String _title(BuildContext context) => switch ((widget.isEditing, _m.isSettlement)) {
        (false, false) => context.l10n.expenseAddTitle,
        (false, true) => context.l10n.expenseAddSettlementTitle,
        (true, false) => context.l10n.expenseEditTitle,
        (true, true) => context.l10n.expenseEditSettlementTitle,
      };

  /// One tap switches between an expense and a settlement (#259, Kenneth
  /// on a device: a title menu's arrow is easy to miss, and a capsule
  /// switch costs the title). The icon is the kind it switches to.
  Widget _kindButton(BuildContext context) => IconButton(
        icon: Icon(_m.isSettlement ? Icons.receipt_long_outlined : Icons.payments_outlined),
        tooltip: _m.isSettlement ? context.l10n.expenseSwitchToExpense : context.l10n.expenseSwitchToSettlement,
        onPressed: _saving
            ? null
            : () => _m.setSettlement(!_m.isSettlement, title: context.l10n.expenseSettlementDefaultTitle),
      );

  /// "Paid by" (#260): the payer by their monogram, opening the
  /// participant sheet.
  Widget _paidByCard(BuildContext context) {
    final l10n = context.l10n;
    final participants = widget.group.participants;
    final payer = participants.where((p) => p.id == _m.paidBy).firstOrNull;
    // A settlement's is "From" (#262).
    final label = _m.isSettlement ? l10n.expenseFromLabel : l10n.expensePaidByLabel;
    return GroupedSection(children: [
      GroupedRow(
        title: Text(label),
        trailing: payer == null
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: [
                Monogram(
                    name: payer.name,
                    color: participantColors(participants, widget.activeUserId)[payer.id]!,
                    radius: 12),
                const SizedBox(width: 8),
                Flexible(child: _value(context, participantName(context, payer, widget.activeUserId))),
              ]),
        onTap: () async {
          _dropFocus();
          final picked = await showParticipantSheet(context,
              title: label,
              participants: participants,
              checkedId: _m.paidBy,
              activeUserId: widget.activeUserId);
          if (picked != null) _m.paidBy = picked;
        },
      ),
    ]);
  }

  /// A field on a card, which draws no box of its own.
  Widget _cell(Widget field) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: field,
      );

  /// A row's value at its end: the rows' text size, dimmed, as iOS's.
  Widget _value(BuildContext context, String value) => Text(value,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: SpliitColors.of(context).secondaryContent));

  String _repeatLabel(RecurrenceRule rule) => switch (rule) {
        RecurrenceRule.none => context.l10n.expenseRepeatNone,
        RecurrenceRule.daily => context.l10n.expenseRepeatDaily,
        RecurrenceRule.weekly => context.l10n.expenseRepeatWeekly,
        RecurrenceRule.monthly => context.l10n.expenseRepeatMonthly,
      };

  /// Before a row opens a picker (#267): a text field that kept its focus
  /// would get it back when the picker closes, and the form would scroll
  /// back up to it.
  void _dropFocus() => FocusManager.instance.primaryFocus?.unfocus();

  /// "Repeat", whose value opens a menu of the choices.
  Widget _repeatRow(BuildContext context) => PopupMenuButton<int>(
        tooltip: context.l10n.expenseRepeatLabel,
        position: PopupMenuPosition.under,
        onOpened: _dropFocus,
        onSelected: (i) => _m.recurrenceRule = RecurrenceRule.values[i],
        itemBuilder: (context) => [
          for (final (i, rule) in RecurrenceRule.values.indexed)
            appPopupMenuItem(
                context,
                i,
                AppMenuItem(
                    label: _repeatLabel(rule), checked: rule == _m.recurrenceRule, onSelected: () {}),
                choice: true),
        ],
        child: GroupedRow(
          title: Text(context.l10n.expenseRepeatLabel),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            _value(context, _repeatLabel(_m.recurrenceRule)),
            const Icon(Icons.arrow_drop_down),
          ]),
        ),
      );

  Widget _form(BuildContext context) {
    final l10n = context.l10n;
    // Today's look, for the fields steps 3-5 of #256 restyle.
    final pageTheme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        // Adding or editing is a task finished or abandoned (#259): ✕
        // closes, asking first if anything changed, and ✓ saves. It asks
        // the form itself rather than waiting on PopScope, which learns
        // of a change a frame later.
        leading: CloseButton(
            onPressed: () => _hasChanges ? _confirmLeave() : Navigator.of(context).maybePop()),
        title: Text(_title(context)),
        centerTitle: false,
        actions: [
          TopBarButtons(children: [
            _kindButton(context),
            _saving
                ? const SizedBox.square(
                    dimension: TopBarButtons.size,
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.check),
                    tooltip: l10n.expenseSaveButton,
                    onPressed: _save,
                  ),
          ]),
        ],
      ),
      body: Theme(
        // Fields sit on the cards, so they draw no box of their own.
        data: pageTheme.copyWith(
          inputDecorationTheme: InputDecorationTheme(
            // A placeholder in the rows' dimmed color, as their values.
            hintStyle: TextStyle(color: SpliitColors.of(context).secondaryContent),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            filled: false,
          ),
        ),
        child: GroupedScrollClip(
          child: SingleChildScrollView(
            controller: _scroll,
            padding: withBottomInset(context, const EdgeInsets.symmetric(vertical: 16)),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Why the last save failed, where the list scrolls to.
                  if (_saveError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: ErrorMessage(_saveError!, diagnostics: _saveErrorDiagnostics),
                    ),
                  // The scanner reads expenses, not settlements.
                  if (_offersScan && !_m.isSettlement) _scanSection(context),
                  GroupedSection(children: [
                    _cell(TextFormField(
                      controller: _m.titleController,
                      decoration: InputDecoration(
                          labelText: l10n.expenseTitleLabel, helperText: _scanHint(_scanFill?.titleHint)),
                      validator: (v) => (v == null || v.isEmpty) ? l10n.commonRequired : null,
                    )),
                    // A settlement has no category (#259): see
                    // ExpenseFormModel.categoryToSave.
                    if (!_m.isSettlement)
                      GroupedRow(
                        leading: CategoryIconGlyph(category: _selectedCategory, size: 24),
                        title: Text(l10n.expenseCategoryLabel),
                        subtitle: switch (_scanHint(switch (_scanFill?.categoryHint) {
                          final id? => localizedCategoryLabel(
                              context, id, _categories.where((c) => c.id == id).firstOrNull),
                          null => null,
                        })) {
                          final hint? => Text(hint),
                          null => null,
                        },
                        trailing: _value(context, localizedCategoryLabel(context, _m.category, _knownCategory)),
                        onTap: _pickCategory,
                      ),
                    GroupedRow(
                      title: Text(l10n.expenseDateLabel),
                      subtitle: switch (_scanHint(_scanFill?.dateHint)) {
                        final hint? => Text(hint),
                        null => null,
                      },
                      trailing: _value(context, formatDate(_m.date, locale: context.appLocale)),
                      onTap: _pickDate,
                    ),
                    _repeatRow(context),
                  ]),
                  CurrencyCard(
                    model: _m,
                    onPickPaidIn: _pickPaidIn,
                    onSwapRate: _swapRate,
                    rateStatus: _m.converting ? _rateStatus(context) : null,
                    onUsePublishedRate: _canRefreshRate ? () => _lookUpRate(force: true) : null,
                    amountHint: _scanHint(_scanFill?.amountHint),
                    calculatedKey: _calculatedKey,
                  ),
                  _paidByCard(context),
                  SplitCard(model: _m, showErrors: _hasAttemptedSave, footerKey: _paidForFooterKey),
                  ReceiptsCard(controller: _receipts, onAdd: _addReceipt, keepsUnsent: !widget.isEditing),
                  // Last: receipts hardly change height, notes can be long
                  // (#268). Past 12 lines they scroll inside the field.
                  GroupedSection(
                    caption: l10n.expenseNotesLabel,
                    children: [
                      _cell(TextFormField(
                        controller: _m.notesController,
                        decoration: InputDecoration(hintText: l10n.expenseNotesHint),
                        minLines: 1,
                        maxLines: 12,
                        maxLength: 5000, // matches Spliit's EXPENSE_NOTES_MAX
                      )),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    _dropFocus();
    final picked = await showDatePicker(
      context: context,
      initialDate: _m.date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      _m.setDate(picked);
      // The new day's rate, into a field that isn't the user's.
      unawaited(_lookUpRate());
    }
  }

  /// Opens the category picker (issue #19): grouped by
  /// [Category.grouping] (matching how the server's own list is already
  /// laid out) and filterable by a type-ahead search field, rather than
  /// one long flat dropdown of 40+ categories.
  Future<void> _pickCategory() async {
    _dropFocus();
    final picked = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CategoryPicker(categories: _categories, selectedId: _m.category),
    );
    if (picked != null) {
      _m.setCategory(picked.id);
    }
  }

  /// "Paid in" (#252), the shared currency picker (issue #23) without a
  /// Custom option: a conversion needs an ISO code on both sides, so the
  /// row only shows in a group that has one.
  Future<void> _pickPaidIn() async {
    _dropFocus();
    final picked = await pickCurrency(
      context,
      currencies: supportedCurrencies,
      selectedCode: _m.paidIn ?? '',
    );
    if (picked == null || !_m.choosePaidIn(picked.code)) return;
    setState(() => _foundRate = null);
    unawaited(_loadRateOrder());
    unawaited(_lookUpRate());
  }

  Future<void> _save() async {
    setState(() {
      _hasAttemptedSave = true;
      _saveError = null;
      _saveErrorDiagnostics = null;
    });
    // Each refusal below says why on screen; the haptic says to look.
    final invalid = _formKey.currentState!.validateGranularly();
    if (invalid.isNotEmpty) return _refuse(invalid);
    // The split first: a settlement's amount is its To amounts' sum.
    if (_m.splitProblem() != null) return _refuse();
    final amounts = _m.amountsToSave();
    if (amounts == null) return _refuse();
    final paidFor = _m.paidFor();
    if (paidFor == null) return _refuse();

    // A new expense keeps photos that didn't upload, and syncs with them
    // later (#124); only ones still on their way hold it back. An edit is
    // online-only: each new photo is uploaded or removed first, as before.
    if (_receipts.busy) {
      setState(() => _saveError = context.l10n.expenseReceiptsWaitBeforeSave);
      _scrollToTop();
      return _refuse();
    }
    if (widget.isEditing && _receipts.hasFailed) {
      setState(() => _saveError = context.l10n.expenseReceiptsUploadOrRemove);
      _scrollToTop();
      return _refuse();
    }

    setState(() => _saving = true);

    // One catch for both paths (#119 review): an edit's request, and a new
    // expense's local database writes, which used to fail with the form
    // stuck on "Saving…".
    try {
      if (widget.isEditing) {
        await _saveEdit(amounts, paidFor);
      } else {
        await _saveNew(amounts, paidFor);
      }
    } catch (e, st) {
      final error = ErrorReporter.instance.report(e, st,
          operation: widget.isEditing
              ? 'Saving expense ${widget.existingExpense!.id}'
              : 'Adding an expense to ${widget.group.id}');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = errorMessageFor(context, error, unexpected: context.l10n.expenseEditSaveFailed);
        _saveErrorDiagnostics = error.diagnostics;
      });
      _scrollToTop();
    }
  }

  /// Says no, and scrolls to the first thing that's wrong (#259): one of
  /// the [invalid] fields, the split, or a calculated amount, whichever is
  /// highest.
  void _refuse([Set<FormFieldState<Object?>> invalid = const {}]) {
    unawaited(Haptics.refused());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final problems = [
        for (final field in invalid) field.context,
        if ((_m.splitProblem() != null || (_m.isSettlement && _m.convertedAmountInvalid),
            _paidForFooterKey.currentContext) case (true, final footer?))
          footer,
        if ((_m.convertedAmountInvalid, _calculatedKey.currentContext) case (true, final amount?)) amount,
      ];
      BuildContext? first;
      double? top;
      for (final problem in problems) {
        final box = problem.findRenderObject();
        if (box is! RenderBox || !box.attached) continue;
        final y = box.localToGlobal(Offset.zero).dy;
        if (top == null || y < top) (first, top) = (problem, y);
      }
      if (first != null) {
        unawaited(Scrollable.ensureVisible(first,
            alignment: 0.2, duration: const Duration(milliseconds: 300), curve: Curves.easeOut));
      }
    });
  }

  /// Up to why the save failed, at the top of the list (#259).
  void _scrollToTop() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut));
        }
      });

  /// Only takes effect after a save actually *succeeds* -- a split
  /// remembered from a save the server rejected would wrongly go on
  /// prefilling future expenses (issue #29 section 7). No-op for a
  /// settlement (the toggle is hidden for one, but this is the real
  /// gate) or when the toggle wasn't checked.
  ///
  /// Never fails the save (#119 review): the expense is already saved, so
  /// a failure here is reported in a snack bar and the form still closes.
  /// Retrying the save would add the expense a second time, and the split
  /// can be saved as the default with the next expense.
  Future<void> _rememberDefaultSplitIfRequested(List<ExpenseShare> paidFor) async {
    if (!_m.saveDefaultSplit || _m.isSettlement) return;
    try {
      await widget.db.setDefaultSplit(
        widget.group.id,
        DefaultSplit.remembering(
          splitMode: _m.splitMode,
          paidFor: paidFor,
          allParticipants: widget.group.participants,
        ),
      );
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Saving the default split for ${widget.group.id}');
      if (!mounted) return;
      showErrorSnackBar(context, context.l10n.expenseDefaultSplitSaveFailed,
          diagnostics: error.diagnostics);
    }
  }

  Future<void> _saveNew(ExpenseAmounts amounts, List<ExpenseShare> paidFor) async {
    final expense = Expense(
      id: const Uuid().v4(),
      groupId: widget.group.id,
      title: _m.titleController.text.trim(),
      amountCents: amounts.amount,
      paidBy: _m.paidBy!,
      paidFor: paidFor,
      splitMode: _m.splitModeToSave,
      category: _m.categoryToSave,
      notes: _m.notesController.text.trim(),
      date: _m.date,
      isSettlement: _m.isSettlement,
      recurrenceRule: _m.recurrenceRule,
      originalAmountCents: amounts.originalAmount,
      originalCurrency: amounts.originalCurrency,
      conversionRate: amounts.conversionRate,
      pending: true,
      createdAt: DateTime.now(),
      documents: _receipts.documents,
      documentCount: _receipts.documents.length,
    );

    // Written locally first -- this succeeds regardless of connectivity,
    // which is the entire point. The outbox (triggered by the caller
    // after this returns) is what attempts the real sync. Who added it is
    // captured now, not when the outbox replays it (issue #92).
    // With its photos that didn't upload, in one step (#124): a retried
    // Save must never add the expense twice.
    final addedBy = await _activityParticipant();
    await _receipts.keepUnsent(
        expenseId: expense.id,
        save: (attachments) => widget.db.insertPending(expense,
            addedByParticipantId: addedBy, attachments: attachments));
    await _rememberDefaultSplitIfRequested(paidFor);

    unawaited(Haptics.saved());
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Who to credit in Spliit's activity log for this save (issue #92):
  /// the group's active user as stored right now, via
  /// [activityParticipantId]. Read from the db rather than taken as a
  /// constructor param, so every way into this screen (the expense list,
  /// Balances' "mark as paid", Activity) attributes the same way.
  Future<String?> _activityParticipant() async {
    final row = await widget.db.groupRow(widget.group.id);
    return activityParticipantId(
      storedActiveParticipantId: row?.activeParticipantId,
      participants: widget.group.participants,
    );
  }

  /// Online-only (see class doc comment): no local pending row, no
  /// outbox -- just a direct [SpliitClient.updateExpense] call. On
  /// failure (most commonly: offline), stays on the form with an error
  /// rather than silently queuing anything, since there's no queueing
  /// path for edits.
  Future<void> _saveEdit(ExpenseAmounts amounts, List<ExpenseShare> paidFor) async {
    await widget.client.updateExpense(
      groupId: widget.group.id,
      expenseId: widget.existingExpense!.id,
      title: _m.titleController.text.trim(),
      amountCents: amounts.amount,
      paidBy: _m.paidBy!,
      paidFor: paidFor,
      splitMode: _m.splitModeToSave,
      category: _m.categoryToSave,
      notes: _m.notesController.text.trim(),
      date: _m.date,
      isSettlement: _m.isSettlement,
      recurrenceRule: _m.recurrenceRule,
      saveDefaultSplittingOptions: _m.saveDefaultSplit,
      // The ones still attached, plus uploads: Spliit deletes any not
      // sent back (#128), and keeps the ids it's sent.
      documents: _receipts.documents,
      originalAmountCents: amounts.originalAmount,
      originalCurrency: amounts.originalCurrency,
      conversionRate: amounts.conversionRate,
      participantId: await _activityParticipant(),
    );
    // A refresh fetched before this edit mustn't write the old copy
    // back over it (issue #90).
    widget.db.markExpensesChanged(widget.group.id);
    // Update keeps the ids sent, so these are the server's now (#123).
    // Best effort: the edit is saved either way.
    try {
      await widget.db.cacheExpenseDocuments(
          widget.group.id, widget.existingExpense!.id, _receipts.documents);
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Storing an edited expense\'s receipts');
    }
    await _rememberDefaultSplitIfRequested(paidFor);
    unawaited(Haptics.saved());
    if (mounted) Navigator.of(context).pop(true);
  }
}

/// Where Scan receipt is (#125). [modelMissing]: the picked language's
/// model isn't on the phone any more (#153).
enum _Scan { idle, reading, filled, hintsOnly, nothing, failed, modelMissing }

/// What a reading put in the form (#153), and for the date and category
/// what they were before, so reading the photo again can take it back.
/// Where the rate lookup stands (#252).
enum _RateState { idle, loading, found, noRate, unavailable }

class _ScanFilled {
  String? title;
  String? amount;

  /// The field [amount] went in: the amount, or "Amount paid" (#252).
  TextEditingController? amountField;
  (DateTime, DateTime)? date;
  (int, int)? category;
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
        : widget.categories
            .where((c) => categoryMatchesQuery(context.appLocale, c, query))
            .toList();
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
                                localizedCategoryGrouping(context, section.key),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelLarge
                                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
                              ),
                            ),
                            for (final c in section.value)
                              ListTile(
                                leading: CategoryIconGlyph(category: c, size: 28),
                                title: Text(localizedCategoryName(context, c)),
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
