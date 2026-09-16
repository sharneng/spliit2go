import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/expense.dart';
import '../models/group.dart';

/// Talks to a self-hosted (or spliit.app) instance's tRPC API as plain
/// HTTP+JSON, deliberately *not* using generated/inferred types from the
/// server. See decisions/mobile-platform.md in the project docs for why:
/// short version, coupling this app's build to Spliit's live server types
/// would stop the two from evolving independently.
///
/// tRPC queries are GET requests with the input JSON-encoded in the
/// `input` query param; mutations are POST with a JSON body. Both use the
/// superjson wire format, which wraps the plain JSON payload with a `json`
/// key plus a `meta` key describing any non-JSON-native types (Date,
/// Decimal, etc.) -- see `_unwrapSuperjson` / `_wrapSuperjson` below.
class SpliitClient {
  /// TODO: point this at your instance, or load from lib/api/local_config.dart
  /// (gitignored) instead of hardcoding it here.
  final String baseUrl;
  final http.Client _http;

  SpliitClient({required this.baseUrl, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Uri _trpcUri(String procedure, {Map<String, dynamic>? input}) {
    final path = '$baseUrl/api/trpc/$procedure';
    if (input == null) return Uri.parse(path);
    final encoded = Uri.encodeComponent(jsonEncode({'json': input}));
    return Uri.parse('$path?input=$encoded');
  }

  /// Fetches a group's expenses. Maps the response into our own [Expense]
  /// DTOs -- this is the one place that needs to change if Spliit's
  /// `groups.expenses.list`-equivalent procedure or its response shape
  /// changes upstream.
  Future<List<Expense>> fetchExpenses(String groupId) async {
    final uri = _trpcUri('groups.expenses.list', input: {'groupId': groupId});
    final res = await _http.get(uri);
    _checkOk(res);
    final data = _unwrapSuperjson(jsonDecode(res.body));

    // TODO: confirm actual field names against a live instance -- these
    // are placeholders based on Spliit's public schema, not yet verified
    // end-to-end. That verification is task (1) from the project plan:
    // a standalone script exercising this client against a real instance.
    return (data as List).map((raw) {
      final m = raw as Map<String, dynamic>;
      return Expense(
        id: m['id'] as String,
        groupId: groupId,
        title: m['title'] as String,
        amountCents: (m['amount'] as num).round(),
        paidBy: m['paidBy'] as String,
        date: DateTime.parse(m['expenseDate'] as String),
        createdAt: m['createdAt'] != null
            ? DateTime.parse(m['createdAt'] as String)
            : null,
      );
    }).toList();
  }

  Future<Group> fetchGroup(String groupId) async {
    final uri = _trpcUri('groups.get', input: {'groupId': groupId});
    final res = await _http.get(uri);
    _checkOk(res);
    final m = _unwrapSuperjson(jsonDecode(res.body)) as Map<String, dynamic>;

    return Group(
      id: m['id'] as String,
      name: m['name'] as String,
      currency: m['currency'] as String,
      participants: (m['participants'] as List)
          .map((p) => Participant(
                id: (p as Map<String, dynamic>)['id'] as String,
                name: p['name'] as String,
              ))
          .toList(),
    );
  }

  /// Creates an expense on the server. Called either immediately (online)
  /// or later by the outbox once connectivity returns (see
  /// lib/sync/outbox.dart) -- this method itself has no offline logic.
  Future<Expense> createExpense({
    required String groupId,
    required String title,
    required int amountCents,
    required String paidBy,
    required DateTime date,
  }) async {
    final uri = _trpcUri('groups.expenses.create');
    final body = _wrapSuperjson({
      'groupId': groupId,
      'title': title,
      'amount': amountCents,
      'paidBy': paidBy,
      'expenseDate': date.toIso8601String(),
    });
    final res = await _http.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    final m = _unwrapSuperjson(jsonDecode(res.body)) as Map<String, dynamic>;

    return Expense(
      id: m['id'] as String,
      groupId: groupId,
      title: title,
      amountCents: amountCents,
      paidBy: paidBy,
      date: date,
    );
  }

  void _checkOk(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SpliitApiException(res.statusCode, res.body);
    }
  }

  dynamic _unwrapSuperjson(dynamic decoded) {
    if (decoded is Map<String, dynamic> && decoded.containsKey('result')) {
      final result = decoded['result'] as Map<String, dynamic>;
      final data = result['data'];
      if (data is Map<String, dynamic> && data.containsKey('json')) {
        return data['json'];
      }
      return data;
    }
    return decoded;
  }

  Map<String, dynamic> _wrapSuperjson(Map<String, dynamic> input) {
    return {'json': input};
  }
}

class SpliitApiException implements Exception {
  final int statusCode;
  final String body;
  SpliitApiException(this.statusCode, this.body);

  @override
  String toString() => 'SpliitApiException($statusCode): $body';
}
