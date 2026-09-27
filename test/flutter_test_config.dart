import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/error_log.dart';

/// Applied to every test file (#133): unexpected errors are collected per
/// test, and one the test didn't declare fails it.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(startErrorLog);
  tearDown(checkErrorLog);
  await testMain();
}
