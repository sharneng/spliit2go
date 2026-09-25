import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/services/error_reporting.dart';

// Issue #119 review: one policy for every error. User errors and expected
// connection failures get guidance only; everything else is unexpected,
// logged once, with diagnostics.
void main() {
  late List<String> logs;
  late DebugPrintCallback originalDebugPrint;
  setUp(() {
    logs = [];
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
  });
  tearDown(() => debugPrint = originalDebugPrint);

  group('classifyError', () {
    test('a missing group is the user\'s', () {
      expect(classifyError(GroupNotFoundException('https://x.test', 'g1')), ErrorKind.user);
    });

    test('offline, timeouts and a briefly unavailable server are connection problems', () {
      for (final e in [
        const SocketException('Failed host lookup'),
        http.ClientException('Connection closed'),
        TimeoutException('slow'),
        const HttpException('reset'),
        SpliitApiException(503, 'Service Unavailable'),
        SpliitApiException(502, 'Bad Gateway'),
      ]) {
        expect(classifyError(e), ErrorKind.connection, reason: '$e');
      }
    });

    test('everything else is unexpected, including 4xx and malformed responses', () {
      for (final e in [
        SpliitApiException(400, 'bad request'),
        SpliitApiException(500, 'boom'),
        SpliitResponseFormatException('groups.get'),
        StateError('closed database'),
        TypeError(),
        Exception('offline'), // a message isn't a classification
        'a thrown string',
      ]) {
        expect(classifyError(e), ErrorKind.unexpected, reason: '$e');
      }
    });
  });

  group('ErrorReporter.report', () {
    test('user and connection errors are neither logged nor given diagnostics', () {
      final reporter = ErrorReporter();
      for (final e in [GroupNotFoundException('https://x.test', 'g1'), http.ClientException('offline')]) {
        final r = reporter.report(e, StackTrace.current, operation: 'Joining');
        expect(r.diagnostics, isNull);
      }
      expect(logs, isEmpty);
    });

    test('an unexpected error is logged once, with its operation, error and stack', () {
      final reporter = ErrorReporter();
      final error = StateError('boom');
      final r = reporter.report(error, StackTrace.fromString('#0 f (x.dart:1)'), operation: 'Saving');
      reporter.report(error, StackTrace.current, operation: 'Saving again');

      expect(r.isUnexpected, isTrue);
      expect(r.diagnostics, contains('Saving failed.'));
      expect(r.diagnostics, contains('Bad state: boom'));
      expect(r.diagnostics, contains('#0 f (x.dart:1)'));
      expect(logs, hasLength(1));
    });
  });

  group('uncaught errors', () {
    test('are logged and kept for presentation, but not if a screen already reported them', () {
      final reporter = ErrorReporter();
      final handled = StateError('handled then rethrown');
      reporter.report(handled, null, operation: 'Saving');
      reporter.reportUncaught(handled, null, operation: 'Unhandled async error');
      expect(logs, hasLength(1));
      expect(reporter.uncaught.value, isNull);

      final fresh = StateError('nobody caught me');
      reporter.reportUncaught(fresh, StackTrace.current, operation: 'Unhandled async error');
      expect(logs, hasLength(2));
      expect(reporter.uncaught.value!.error, same(fresh));
      expect(reporter.uncaught.value!.diagnostics, contains('nobody caught me'));
    });

    test('framework and async failures both reach the same reporter, once each', () {
      final reporter = ErrorReporter();
      final previousFlutter = FlutterError.onError;
      final previousAsync = PlatformDispatcher.instance.onError;
      final presented = <FlutterErrorDetails>[];
      FlutterError.onError = presented.add;
      addTearDown(() {
        FlutterError.onError = previousFlutter;
        PlatformDispatcher.instance.onError = previousAsync;
      });

      installErrorHandlers(reporter);

      final buildError = StateError('during build');
      FlutterError.onError!(FlutterErrorDetails(exception: buildError, library: 'widgets library'));
      expect(presented, hasLength(1)); // still printed the usual way
      expect(reporter.uncaught.value!.error, same(buildError));
      expect(reporter.uncaught.value!.operation, 'Flutter (widgets library)');

      final asyncError = StateError('in a future');
      expect(PlatformDispatcher.instance.onError!(asyncError, StackTrace.current), isTrue);
      expect(reporter.uncaught.value!.error, same(asyncError));

      // The same error surfacing twice (framework, then zone) logs once.
      PlatformDispatcher.instance.onError!(buildError, StackTrace.current);
      expect(logs.where((l) => l.contains('during build')), hasLength(1));
      expect(logs.where((l) => l.contains('in a future')), hasLength(1));
    });
  });

  test('a missing platform plugin is recognized', () {
    expect(isMissingPlugin(MissingPluginException('no connectivity')), isTrue);
    expect(isMissingPlugin(StateError('x')), isFalse);
  });
}
