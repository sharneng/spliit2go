import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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
  await _loadRoboto();
  await testMain();
}

/// The theme's Roboto, from Flutter's own copy (#263), in place of the test
/// font's 1em-wide glyphs: what's measured to fit (the split modes) fits
/// in tests as on a phone. Regular, medium and semibold-or-bolder weights.
Future<void> _loadRoboto() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null) return;
  final fonts = Directory('$flutterRoot/bin/cache/artifacts/material_fonts');
  final loader = FontLoader('Roboto');
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final file = File('${fonts.path}/$name');
    if (file.existsSync()) loader.addFont(file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
  }
  await loader.load();
}
