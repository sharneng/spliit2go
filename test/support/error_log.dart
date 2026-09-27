import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/error_reporting.dart';

/// Unexpected errors in tests (#133). A passing run prints nothing: every
/// test gets a fresh [ErrorReporter.instance] that collects what it would
/// log (see `flutter_test_config.dart`), and an unexpected error the test
/// didn't declare with [expectUnexpectedError] fails it, with the details.

final _logged = <ReportedError>[];
final _expected = <Pattern>[];

/// The unexpected errors logged so far in this test.
List<ReportedError> get loggedUnexpectedErrors => List.unmodifiable(_logged);

/// Declares that this test logs at least one unexpected error whose
/// operation contains [operation], e.g. `'Loading categories'`.
void expectUnexpectedError(Pattern operation) => _expected.add(operation);

/// Before each test: a reporter that collects instead of printing.
void startErrorLog() {
  _logged.clear();
  _expected.clear();
  ErrorReporter.instance = ErrorReporter(log: _logged.add);
}

/// After each test: every logged error was declared, and every declared
/// one was logged.
void checkErrorLog() {
  bool matches(Pattern p, ReportedError e) => e.operation.contains(p);
  final undeclared = [
    for (final e in _logged)
      if (!_expected.any((p) => matches(p, e))) e,
  ];
  final missing = [
    for (final p in _expected)
      if (!_logged.any((e) => matches(p, e))) p,
  ];
  if (undeclared.isEmpty && missing.isEmpty) return;
  fail([
    for (final e in undeclared)
      'Unexpected error not declared with expectUnexpectedError:\n${e.diagnostics}',
    for (final p in missing) 'Declared an unexpected error from "$p", but none was logged.',
  ].join('\n\n'));
}
