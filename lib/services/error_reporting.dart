import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../api/spliit_client.dart';

/// The app's one policy for errors (issue #118, #119 review): what kind
/// an error is decides what the user sees and whether it's logged.
///
/// - [user]: the user's input or the data they asked for is the problem
///   (a group that doesn't exist, say). Guidance only: no log, no details.
/// - [connection]: expected operational failures (offline, a timeout, the
///   server briefly unavailable). Not the user's fault, not a bug: "check
///   your connection and try again", no log, no details.
/// - [unexpected]: everything else (a malformed response, a failed type
///   cast, a database failure, anything unknown). Catching it doesn't make
///   it expected: logged once with its stack trace, a short message, and
///   the diagnostics one tap away.
enum ErrorKind { user, connection, unexpected }

/// An error that is the user's (or their data's) doing, for which the
/// screen has specific guidance. See [ErrorKind.user].
abstract interface class UserError implements Exception {}

/// The response didn't have the shape Spliit's API documents: a service
/// or schema problem, never the user's (see [ErrorKind.unexpected]).
class SpliitResponseFormatException implements Exception {
  final String message;
  SpliitResponseFormatException(this.message);

  @override
  String toString() => 'SpliitResponseFormatException: $message';
}

/// Which [ErrorKind] [error] is. Only specific, known cases are expected;
/// anything unrecognized is [ErrorKind.unexpected].
ErrorKind classifyError(Object error) {
  if (error is UserError) return ErrorKind.user;
  if (error is SocketException ||
      error is HttpException ||
      error is http.ClientException ||
      error is TimeoutException) {
    return ErrorKind.connection;
  }
  // The server said it's temporarily unable to answer.
  if (error is SpliitApiException && const {502, 503, 504}.contains(error.statusCode)) {
    return ErrorKind.connection;
  }
  return ErrorKind.unexpected;
}

/// A classified error, ready for a screen to present.
class ReportedError {
  final ErrorKind kind;
  final Object error;
  final StackTrace? stackTrace;

  /// What was being done, e.g. "Joining https://spliit.app/groups/abc".
  final String operation;

  ReportedError(this.kind, this.error, this.stackTrace, this.operation);

  bool get isUnexpected => kind == ErrorKind.unexpected;

  /// The copyable details: only for [ErrorKind.unexpected]; the other
  /// kinds are explained by their message alone.
  String? get diagnostics => isUnexpected
      ? '$operation failed.\n\n$error${stackTrace == null ? '' : '\n\n$stackTrace'}'
      : null;
}

/// Classifies errors, logs the unexpected ones once, and keeps the last
/// uncaught one for the app to present (see [installErrorHandlers]).
class ErrorReporter {
  ErrorReporter();

  /// The app's reporter. Screens use this; tests may replace it.
  static ErrorReporter instance = ErrorReporter();

  /// The latest uncaught error, for the app shell to show once the UI can
  /// (after the current frame), rather than from inside a failed build.
  final ValueNotifier<ReportedError?> uncaught = ValueNotifier(null);

  final _reported = Expando<bool>('reported');

  /// Classifies [error] from [operation] and logs it if it's unexpected.
  /// Screens call this from their catch blocks and present the result.
  ReportedError report(Object error, StackTrace? stackTrace, {required String operation}) {
    final reported = ReportedError(classifyError(error), error, stackTrace, operation);
    if (reported.isUnexpected && _markReported(error)) _log(reported);
    return reported;
  }

  /// An error nothing caught: always unexpected. Logged and kept for
  /// presentation, unless a screen already reported this same error and
  /// it was rethrown (no double reporting).
  void reportUncaught(Object error, StackTrace? stackTrace, {required String operation}) {
    if (!_markReported(error)) return;
    final reported = ReportedError(ErrorKind.unexpected, error, stackTrace, operation);
    _log(reported);
    uncaught.value = reported;
  }

  /// True the first time [error] is seen. Strings, numbers and the like
  /// can't be tracked, so they always count as new.
  bool _markReported(Object error) {
    try {
      if (_reported[error] == true) return false;
      _reported[error] = true;
    } on ArgumentError {
      // Not trackable by identity; report it.
    }
    return true;
  }

  void _log(ReportedError r) => debugPrint('Unexpected error: ${r.diagnostics}');
}

/// Routes errors nothing caught, from the framework and from async code,
/// to [reporter] (issue #119 review). Kept in one place so tests can call
/// it and restore the previous handlers.
void installErrorHandlers(ErrorReporter reporter) {
  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    // Still prints it the usual way in debug builds.
    (previousFlutter ?? FlutterError.presentError)(details);
    reporter.reportUncaught(details.exception, details.stack,
        operation: 'Flutter (${details.library ?? 'framework'})');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    reporter.reportUncaught(error, stack, operation: 'Unhandled async error');
    return true;
  };
}

/// Platform plugins missing on this platform (widget tests, desktop) are
/// expected where the code already has a fallback.
bool isMissingPlugin(Object error) => error is MissingPluginException;
