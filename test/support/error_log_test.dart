import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/error_reporting.dart';

import 'error_log.dart';

// Issue #133: the harness in flutter_test_config.dart. Each case checks
// the log itself, then starts a fresh one so the real tear-down passes.
void main() {
  void report(String operation) =>
      ErrorReporter.instance.report(StateError('boom'), StackTrace.current, operation: operation);

  test('unexpected errors are collected, not printed', () {
    final printed = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message);
    try {
      expectUnexpectedError('Loading categories');
      report('Loading categories');
    } finally {
      debugPrint = original;
    }
    expect(printed, isEmpty);
    expect(loggedUnexpectedErrors.single.operation, 'Loading categories');
    checkErrorLog();
  });

  test('an undeclared unexpected error fails the test, with its details', () {
    report('Loading categories');
    expect(checkErrorLog,
        throwsA(isA<TestFailure>().having((f) => f.message, 'message',
            allOf(contains('not declared'), contains('Loading categories failed.'), contains('boom')))));
    startErrorLog();
  });

  test('a declared error that never happens fails the test', () {
    expectUnexpectedError('Saving group');
    expect(checkErrorLog,
        throwsA(isA<TestFailure>().having((f) => f.message, 'message', contains('"Saving group"'))));
    startErrorLog();
  });

  test('a connection error is not logged, so needs no declaring', () {
    ErrorReporter.instance.report(TimeoutException('slow'), null, operation: 'Refreshing group g1');
    expect(loggedUnexpectedErrors, isEmpty);
  });
}
