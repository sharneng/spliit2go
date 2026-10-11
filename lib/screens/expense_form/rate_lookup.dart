import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';

import '../../services/error_reporting.dart';
import '../../services/exchange_rates.dart';
import '../../services/settings_service.dart';
import 'expense_form_model.dart';

/// Where the rate lookup stands (#252).
enum RateLookupState { idle, loading, found, noRate, unavailable }

/// Looks up the published rate for [model]'s conversion (#252) and
/// remembers which currency of the pair this device writes first (#261),
/// apart from the screen (#289). The rate goes into the field only where
/// [ExpenseFormModel.fillRate] lets it; otherwise the card's footer
/// quotes it.
class RateLookup extends ChangeNotifier {
  RateLookup({required this.rates, required this.settings, required this.model});

  final ExchangeRates rates;
  final SettingsService settings;
  final ExpenseFormModel model;

  RateLookupState _state = RateLookupState.idle;
  RateLookupState get state => _state;

  /// The published rate last found, for the footer.
  ExchangeRate? _found;
  ExchangeRate? get found => _found;

  /// Which lookup is current: an answer to an older one is ignored.
  int _lookups = 0;

  /// Taps on the pair, so a saved order read since doesn't undo one.
  int _swaps = 0;

  bool _disposed = false;

  void _update(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  /// Asks for the rate of the paid-in currency on the expense's day. It's
  /// filled in only into an empty or auto-filled field, or always for
  /// [force] ("Use the published rate"); otherwise the footer quotes it.
  Future<void> lookUp({bool force = false}) async {
    final lookup = ++_lookups;
    final edits = model.rateEdits;
    final from = model.paidIn, to = model.group.currencyCode;
    if (!model.converting || from == null || to == null) {
      _update(() => _state = RateLookupState.idle);
      return;
    }
    // Looked up even for a rate of the user's: the footer quotes the
    // published one (#261), which fillRate puts only where it may.
    _update(() => _state = RateLookupState.loading);
    RateLookupState state;
    ExchangeRate? found;
    try {
      found = await rates.rate(model.date, from, to, force: force);
      state = RateLookupState.found;
    } on NoPublishedRate {
      state = RateLookupState.noRate;
    } on RatesUnavailable {
      state = RateLookupState.unavailable;
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Looking up the $from to $to rate');
      state = RateLookupState.unavailable;
    }
    // An answer to a question the form isn't asking any more.
    if (_disposed || lookup != _lookups) return;
    _update(() {
      _state = state;
      _found = found;
    });
    if (found != null) model.fillRate(found.rate, force: force, editsAtRequest: edits);
  }

  /// A conversion was opened, or another currency picked: the pair's
  /// order, and its rate.
  void pairChanged() {
    _update(() => _found = null);
    unawaited(loadOrder());
    unawaited(lookUp());
  }

  /// "Use the published rate": when the field isn't it, or to try again.
  bool get canRefresh => switch (_state) {
        RateLookupState.loading || RateLookupState.idle => false,
        RateLookupState.found => switch (_found) {
            final found? => found.offline || !model.showsRate(found.rate),
            null => false,
          },
        RateLookupState.noRate || RateLookupState.unavailable => true,
      };

  /// A tap on the pair (#261): the other currency first, remembered on
  /// this device for the pair.
  void swap() {
    _swaps++;
    model.swapRatePair();
    final (paidIn, own, first) = (model.paidIn, model.group.currencyCode, model.rateBaseCode);
    if (paidIn == null || own == null || first == null) return;
    unawaited(settings.setRateBase(paidIn, own, first).catchError((Object e, StackTrace st) {
      ErrorReporter.instance.report(e, st, operation: 'Saving the exchange rate order');
    }));
  }

  /// Which currency of the pair the rate is written with first (#261):
  /// the one this device swapped to, otherwise the more valuable by the
  /// newest saved rates.
  Future<void> loadOrder() async {
    final (paidIn, own, swaps) = (model.paidIn, model.group.currencyCode, _swaps);
    if (!model.converting || paidIn == null || own == null) return;
    final ranking = await rates.ranking();
    String? base;
    try {
      base = await settings.rateBase(paidIn, own);
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Reading the exchange rate order');
    }
    if (_disposed || model.paidIn != paidIn) return;
    model.ranking = ranking;
    // A swap made while this was being read is newer (#270 review).
    if (_swaps == swaps) model.rateBase = base;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
