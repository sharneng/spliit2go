import 'package:flutter/widgets.dart';

import '../../models/category.dart';
import '../../services/error_reporting.dart';
import '../../services/receipt_fill.dart';
import '../../services/receipt_photo.dart';
import '../../services/receipt_scanner.dart';
import '../../services/receipt_text.dart';
import '../../services/settings_service.dart';
import 'expense_form_model.dart';

/// Where Scan receipt is (#125). [modelMissing]: the picked language's
/// model isn't on the phone any more (#153).
enum ReceiptScanStatus { idle, reading, filled, hintsOnly, nothing, failed, modelMissing }

/// Scan receipt's state (#125, #153), apart from the screen (#289): the
/// receipt language, reading a photo into [model], and reading the same
/// photo again in another language. Choosing the photo, and the sheets
/// that ask, stay with the screen, which has the context.
class ReceiptScanController extends ChangeNotifier {
  ReceiptScanController({
    required this.scanner,
    required this.settings,
    required this.groupId,
    required this.model,
    this.onDateFilled,
  });

  final ReceiptScanner scanner;
  final SettingsService settings;
  final String groupId;
  final ExpenseFormModel model;

  /// The receipt put its date in the form: that day has its own rate
  /// (#252).
  final VoidCallback? onDateFilled;

  ReceiptScanStatus _status = ReceiptScanStatus.idle;
  ReceiptScanStatus get status => _status;
  bool get reading => _status == ReceiptScanStatus.reading;

  /// The failed scan's details, for its error.
  String? _diagnostics;
  String? get diagnostics => _diagnostics;

  /// What the last scan left beside the fields it didn't fill.
  ReceiptFill? _fill;
  ReceiptFill? get fill => _fill;

  /// The receipt language (#153): the one picked in this group last, or
  /// else the phone's language when its model is there, or else Latin.
  ReceiptScript _script = ReceiptScript.latin;
  ReceiptScript get script => _script;

  /// The languages whose models are on the phone, as Play services last
  /// said.
  Set<ReceiptScript> _installed = {ReceiptScript.latin};
  Set<ReceiptScript> get installed => _installed;

  /// The language the last scan found missing, for its message.
  ReceiptScript? _missingScript;
  ReceiptScript? get missingScript => _missingScript;

  /// The photo the last scan read, so picking another language reads it
  /// again rather than asking for a new one (#153).
  PreparedReceipt? _photo;

  /// What that reading put in the form, which reading it again in another
  /// language replaces, where the user hasn't changed it.
  _Filled? _filled;

  /// The categories a receipt's category is picked from, as the screen
  /// has them.
  List<Category> categories = const [];

  bool _disposed = false;

  void _update(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  /// Best effort: without an answer from Play services, the picker offers
  /// Latin and asks again when it opens. [phoneLanguage] is the phone's
  /// language code.
  Future<void> loadLanguage(String phoneLanguage) async {
    final phone = ReceiptScript.forLanguage(phoneLanguage);
    var installed = _installed;
    ReceiptScript? picked;
    try {
      installed = await scanner.installedScripts();
    } catch (e, st) {
      if (!isMissingPlugin(e)) ErrorReporter.instance.report(e, st, operation: 'Listing receipt languages');
    }
    try {
      picked = ReceiptScript.values.asNameMap()[await settings.receiptScript(groupId)];
    } catch (e, st) {
      if (!isMissingPlugin(e)) ErrorReporter.instance.report(e, st, operation: 'Loading the receipt language');
    }
    _update(() {
      _installed = installed;
      _script = [picked, phone].nonNulls.where(installed.contains).firstOrNull ?? ReceiptScript.latin;
    });
  }

  /// The language picker downloaded or removed a model.
  void installedChanged(Set<ReceiptScript> installed) => _update(() {
        _installed = installed;
        if (!installed.contains(_script)) _script = ReceiptScript.latin;
      });

  /// Picks the receipt language and remembers it for the group. Picking
  /// another language after a scan reads that scan's photo again.
  Future<void> pickLanguage(ReceiptScript picked) async {
    final changed = picked != _script;
    _update(() => _script = picked);
    try {
      await settings.setReceiptScript(groupId, picked.name);
    } catch (e, st) {
      // Only the remembering failed; this form still uses it.
      if (!isMissingPlugin(e)) ErrorReporter.instance.report(e, st, operation: 'Saving the receipt language');
    }
    if (changed && _photo != null && !reading && !_disposed) await read(_photo!, again: true);
  }

  /// Takes back what the last reading filled in, where the user hasn't
  /// changed it since, before the same photo is read in another language.
  void _undoFill() {
    final filled = _filled;
    if (filled == null) return;
    final m = model;
    if (filled.title != null && m.titleController.text == filled.title) m.titleController.text = '';
    if (filled.amountField case final field? when field.text == filled.amount) field.text = '';
    if (filled.date case (final date, final before)? when m.date == date) m.setDate(before, chosen: false);
    if (filled.category case (final id, final before)? when m.category == id) m.setCategory(before, chosen: false);
    _filled = null;
  }

  /// Reads [photo] in the picked language and fills the form. [again]:
  /// the same photo in another language, which replaces what the last
  /// reading filled in.
  Future<void> read(PreparedReceipt photo, {bool again = false}) async {
    final script = _script;
    _update(() {
      if (again) _undoFill();
      _photo = photo;
      _filled = null;
      _status = ReceiptScanStatus.reading;
      _fill = null;
      _diagnostics = null;
    });
    try {
      final blocks = await scanner.recognizeText(photo.bytes, script: script);
      final scan = readReceipt(receiptRows(blocks), categories: categories, today: DateTime.now());
      if (_disposed) return;
      // The form as it is now, not as it was when the scan started: the
      // user may have typed meanwhile. During a conversion the total is
      // what was paid, in the currency it was paid in (#252).
      final m = model;
      final paidIn = m.converting && !m.isSettlement;
      final amountField = paidIn ? m.originalAmountController : m.amountController;
      final fill = receiptFill(
        scan,
        ReceiptFormState(
          titleEmpty: m.titleController.text.trim().isEmpty,
          amountEmpty: amountField.text.trim().isEmpty,
          dateChosen: m.dateChosen,
          categoryChosen: m.categoryChosen,
          currencyCode: paidIn ? m.paidIn : m.group.currencyCode,
          currencySymbol: paidIn ? m.paidInSymbol : m.group.currency,
        ),
      );
      final dateBefore = m.date;
      _update(() {
        final filled = _Filled();
        if (fill.title case final title?) m.titleController.text = filled.title = title;
        if (fill.amountCents case final cents?) {
          // A receipt total is read in hundredths whatever the currency.
          amountField.text = filled.amount =
              m.amountText(cents / 100, paidIn ? m.originalDigits : m.digits);
          filled.amountField = amountField;
        }
        if (fill.date case final date?) {
          filled.date = (date, m.date);
          m.setDate(date);
        }
        if (fill.categoryId case final id?) {
          filled.category = (id, m.category);
          m.setCategory(id);
        }
        _filled = filled;
        _fill = fill;
        _status = scan.isEmpty
            ? ReceiptScanStatus.nothing
            : fill.filledAny
                ? ReceiptScanStatus.filled
                : ReceiptScanStatus.hintsOnly;
      });
      if (m.date != dateBefore) onDateFilled?.call();
    } on ReceiptTextModelMissing catch (e) {
      // Removed, or Play services' data was cleared, since the form
      // opened: the picker offers it for download again.
      _update(() {
        _status = ReceiptScanStatus.modelMissing;
        _missingScript = e.script;
        _installed = {..._installed}..remove(e.script);
      });
    } catch (e, st) {
      final error = ErrorReporter.instance.report(e, st, operation: 'Reading a receipt');
      _update(() {
        _status = ReceiptScanStatus.failed;
        _diagnostics = error.diagnostics;
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// What a reading put in the form (#153), and for the date and category
/// what they were before, so reading the photo again can take it back.
class _Filled {
  String? title;
  String? amount;

  /// The field [amount] went in: the amount, or "Amount paid" (#252).
  TextEditingController? amountField;
  (DateTime, DateTime)? date;
  (int, int)? category;
}
