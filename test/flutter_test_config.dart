import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/services/exchange_rates.dart';

import 'support/error_log.dart';

/// Applied to every test file (#133): unexpected errors are collected per
/// test, and one the test didn't declare fails it.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(startErrorLog);
  // Exchange rates (#252) are offline unless a test brings its own.
  setUp(() => ExchangeRates.newClient =
      () => MockClient((_) async => throw http.ClientException('offline in tests')));
  tearDown(checkErrorLog);
  await testMain();
}
