import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/services/error_reporting.dart';

import 'error_log.dart';

// Issue #133: the harness in flutter_test_config.dart. Each failing case
// checks the log itself, then starts a fresh one so the real tear-down
// passes.
void main() {
  void report(Object error, String operation) =>
      ErrorReporter.instance.report(error, StackTrace.current, operation: operation);

  Matcher failsWith(List<String> parts) => throwsA(isA<TestFailure>()
      .having((f) => f.message, 'message', allOf([for (final p in parts) contains(p)])));

  void expectFailure(List<String> parts) {
    expect(checkErrorLog, failsWith(parts));
    startErrorLog();
  }

  test('a declared error is collected, not printed', () {
    final printed = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message);
    try {
      expectUnexpectedError<StateError>('Loading categories');
      report(StateError('boom'), 'Loading categories');
    } finally {
      debugPrint = original;
    }
    expect(printed, isEmpty);
    expect(loggedUnexpectedErrors.single.operation, 'Loading categories');
    checkErrorLog();
  });

  test('an undeclared error fails the test, with its details', () {
    report(StateError('boom'), 'Loading categories');
    expectFailure(['not declared', 'StateError from "Loading categories"', 'Bad state: boom']);
  });

  test('a declared error that never happens fails the test', () {
    expectUnexpectedError<StateError>('Saving group g1');
    expectFailure(['StateError from "Saving group g1" 1 time(s)', 'logged 0 time(s)']);
  });

  // #134 review (Ezra): a declaration is consumed, by type and count.
  test('a different error from the declared operation fails the test', () {
    expectUnexpectedError<SpliitApiException>('Joining https://x.test/groups/g1');
    report(SpliitApiException(500, 'boom'), 'Joining https://x.test/groups/g1');
    report(StateError('unrelated'), 'Joining https://x.test/groups/g1');
    expectFailure(['not declared', 'StateError from "Joining https://x.test/groups/g1"']);
  });

  test('an extra occurrence fails the test', () {
    expectUnexpectedError<StateError>('Saving group g1');
    report(StateError('one'), 'Saving group g1');
    report(StateError('two'), 'Saving group g1');
    expectFailure(['not declared', 'Bad state: two']);
  });

  test('two declarations need two reports', () {
    expectUnexpectedError<StateError>('Saving group g1');
    expectUnexpectedError<StateError>('Saving group g1');
    report(StateError('once'), 'Saving group g1');
    expectFailure(['logged 0 time(s)']);
  });

  test('a count is met exactly', () {
    expectUnexpectedError<StateError>('Syncing expense e1', times: 3);
    for (var i = 0; i < 3; i++) {
      report(StateError('try $i'), 'Syncing expense e1');
    }
    checkErrorLog();
  });

  test('the operation must match exactly, not as a fragment', () {
    expectUnexpectedError<StateError>('Loading');
    report(StateError('boom'), 'Loading categories');
    expectFailure(['not declared', 'logged 0 time(s)']);
  });

  test('a declaration must name the error type', () {
    expect(() => expectUnexpectedError('Loading categories'), throwsArgumentError);
  });

  test('a connection error is not logged, so needs no declaring', () {
    report(TimeoutException('slow'), 'Refreshing group g1');
    expect(loggedUnexpectedErrors, isEmpty);
  });

  test('a request to a client that must not be used fails the test, even when caught', () async {
    final client = SpliitClient(baseUrl: 'https://x.test', httpClient: noRequestsClient());
    await expectLater(client.fetchGroup('g1'), throwsStateError);
    expectFailure(['must not be used', 'https://x.test/api/trpc/groups.get']);
    // The client itself is still an ordinary http client.
    expect(noRequestsClient(), isA<http.Client>());
  });
}
