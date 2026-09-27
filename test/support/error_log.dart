import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/services/error_reporting.dart';

/// Unexpected errors in tests (#133). A passing run prints nothing: every
/// test gets a fresh [ErrorReporter.instance] that collects what it would
/// log (see `flutter_test_config.dart`). Each report must be one the test
/// declared with [expectUnexpectedError], and each declared one must
/// happen, as often as declared; anything else fails the test, with the
/// details.

class _Expected {
  _Expected(this.operation, this.type, this.matches, this.times);
  final String operation;
  final Type type;
  final bool Function(Object error) matches;
  final int times;
  int seen = 0;

  @override
  String toString() => '$type from "$operation"';
}

final _logged = <ReportedError>[];
final _expected = <_Expected>[];
final _requests = <http.BaseRequest>[];

/// The unexpected errors logged so far in this test.
List<ReportedError> get loggedUnexpectedErrors => List.unmodifiable(_logged);

/// Declares that this test logs an unexpected [E] from exactly
/// [operation] (e.g. `'Loading categories'`), [times] times. A report
/// matching no declaration still left fails the test, and so does a
/// declaration not met.
void expectUnexpectedError<E extends Object>(String operation, {int times = 1}) {
  // An untyped declaration would accept a different bug in the same
  // operation (#134 review).
  if (E == Object) throw ArgumentError('expectUnexpectedError needs the error type');
  _expected.add(_Expected(operation, E, (e) => e is E, times));
}

/// A client for tests that must not reach the server. A request fails the
/// test, even if the app catches the error it gets.
http.Client noRequestsClient() => MockClient((req) async {
      _requests.add(req);
      throw StateError('Unexpected request: ${req.method} ${req.url}');
    });

/// Before each test: a reporter that collects instead of printing.
void startErrorLog() {
  _logged.clear();
  _expected.clear();
  _requests.clear();
  ErrorReporter.instance = ErrorReporter(log: _logged.add);
}

/// After each test: every report was declared, every declaration was met
/// as often as declared, and no forbidden request was made.
void checkErrorLog() {
  for (final x in _expected) {
    x.seen = 0;
  }
  final undeclared = <ReportedError>[];
  for (final e in _logged) {
    final match = _expected
        .where((x) => x.seen < x.times && x.operation == e.operation && x.matches(e.error))
        .firstOrNull;
    if (match == null) {
      undeclared.add(e);
    } else {
      match.seen++;
    }
  }
  final unmet = [for (final x in _expected) if (x.seen < x.times) x];
  if (undeclared.isEmpty && unmet.isEmpty && _requests.isEmpty) return;
  fail([
    for (final r in _requests) 'Request to a client that must not be used: ${r.method} ${r.url}',
    for (final e in undeclared)
      'Unexpected error not declared with expectUnexpectedError '
          '(${e.error.runtimeType} from "${e.operation}"):\n${e.diagnostics}',
    for (final x in unmet) 'Declared $x ${x.times} time(s), but it was logged ${x.seen} time(s).',
  ].join('\n\n'));
}
