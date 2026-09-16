import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/expense.dart';
import '../models/group.dart';

/// Talks to a self-hosted (or spliit.app) instance's tRPC API as plain
/// HTTP+JSON, deliberately *not* using generated/inferred types from the
/// server -- see decisions/mobile-platform.md in the project docs for why.
///
/// The request/response shapes here are ported from a Python client
/// (splitwise2spliit's spliit_api.py) that was built and exercised
/// end-to-end against a live instance for a Splitwise CSV import, so
/// they're verified, not guessed:
///
/// - Every call, query or mutation, uses tRPC's *batch* wire format:
///   `?batch=1` plus an `input` (GET) or JSON body (POST) shaped like
///   `{"0": {"json": {...}}}`, and the response is always a JSON array,
///   one entry per batched call -- `resp[0]['result']['data']['json']`
///   even for a single call.
/// - A payload field that must be typed as a JS Date (only expenseDate,
///   here) needs a superjson `meta` entry alongside it, or the server
///   parses it as a plain string.
/// - `groups.expenses.list` paginates at roughly 10 per page; a full
///   fetch has to follow `hasMore`/`nextCursor`.
class SpliitClient {
  final String baseUrl;
  final http.Client _http;

  SpliitClient({required this.baseUrl, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Uri _trpcUri(String procedure, {Map<String, dynamic>? input}) {
    final path = '$baseUrl/api/trpc/$procedure';
    if (input == null) return Uri.parse('$path?batch=1');
    final batched = jsonEncode({'0': {'json': input}});
    return Uri.parse('$path?batch=1&input=${Uri.encodeComponent(batched)}');
  }

  /// Unwraps a batched tRPC response: `[{"result":{"data":{"json": ...}}}]`
  /// (or the non-superjson-wrapped `{"result":{"data": ...}}` for plain
  /// JSON-safe payloads) -> the first call's actual data.
  dynamic _unwrapBatch(dynamic decoded) {
    final first = (decoded as List).first as Map<String, dynamic>;
    if (first.containsKey('error')) {
      throw SpliitApiException(200, jsonEncode(first['error']));
    }
    final data = (first['result'] as Map<String, dynamic>)['data'];
    if (data is Map<String, dynamic> && data.containsKey('json')) {
      return data['json'];
    }
    return data;
  }

  void _checkOk(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SpliitApiException(res.statusCode, res.body);
    }
  }

  /// Fetches group details: name, currency, participants.
  Future<Group> fetchGroup(String groupId) async {
    final uri = _trpcUri('groups.get', input: {'groupId': groupId});
    final res = await _http.get(uri);
    _checkOk(res);
    final data = _unwrapBatch(jsonDecode(res.body)) as Map<String, dynamic>;
    final g = data['group'] as Map<String, dynamic>;

    return Group(
      id: g['id'] as String,
      name: g['name'] as String,
      currency: g['currency'] as String,
      participants: (g['participants'] as List)
          .map((p) => Participant(
                id: (p as Map<String, dynamic>)['id'] as String,
                name: p['name'] as String,
              ))
          .toList(),
    );
  }

  /// Fetches every expense in the group, following pagination.
  Future<List<Expense>> fetchExpenses(String groupId) async {
    final all = <Expense>[];
    String? cursor;
    while (true) {
      final query = <String, dynamic>{'groupId': groupId};
      if (cursor != null) query['cursor'] = cursor;
      final uri = _trpcUri('groups.expenses.list', input: query);
      final res = await _http.get(uri);
      _checkOk(res);
      final data = _unwrapBatch(jsonDecode(res.body)) as Map<String, dynamic>;

      for (final raw in (data['expenses'] as List)) {
        final m = raw as Map<String, dynamic>;
        all.add(Expense(
          id: m['id'] as String,
          groupId: groupId,
          title: m['title'] as String,
          amountCents: (m['amount'] as num).round(),
          paidBy: extractParticipantId(m['paidBy']),
          paidFor: (m['paidFor'] as List? ?? [])
              .map((s) => ExpenseShare.fromJson(s as Map<String, dynamic>))
              .toList(),
          splitMode: SplitModeWire.fromWire(m['splitMode'] as String? ?? 'EVENLY'),
          category: m['category'] == null ? 0 : extractCategoryId(m['category']),
          notes: m['notes'] as String? ?? '',
          date: DateTime.parse(m['expenseDate'] as String),
          isReimbursement: m['isReimbursement'] as bool? ?? false,
        ));
      }

      if (data['hasMore'] != true) break;
      cursor = data['nextCursor'] as String;
    }
    return all;
  }

  Future<Map<int, String>> fetchCategories() async {
    final uri = _trpcUri('categories.list');
    final res = await _http.get(uri);
    _checkOk(res);
    final data = _unwrapBatch(jsonDecode(res.body)) as Map<String, dynamic>;
    return {
      for (final c in (data['categories'] as List))
        (c as Map<String, dynamic>)['id'] as int: c['name'] as String,
    };
  }

  /// Creates an expense (or, with [isReimbursement], a settlement payment)
  /// on the server. Called either immediately (online) or later by the
  /// outbox once connectivity returns (see lib/sync/outbox.dart) -- this
  /// method itself has no offline logic.
  ///
  /// [amountCents] and each [paidFor] share are in cents. For
  /// [SplitMode.evenly], shares is just a nonzero weight (1 per person is
  /// the common case); for [SplitMode.byAmount] it's the exact cents owed.
  Future<String> createExpense({
    required String groupId,
    required String title,
    required int amountCents,
    required String paidBy,
    required List<ExpenseShare> paidFor,
    SplitMode splitMode = SplitMode.evenly,
    int category = 0,
    String notes = '',
    DateTime? date,
    bool isReimbursement = false,
  }) async {
    final expenseDate = (date ?? DateTime.now().toUtc());
    // Matches the Python client's formatting: millisecond precision, 'Z'
    // suffix, regardless of the platform's default ISO-8601 rendering.
    final ms = expenseDate.millisecondsSinceEpoch % 1000;
    final formattedDate =
        '${expenseDate.toUtc().toIso8601String().split('.').first}.${ms.toString().padLeft(3, '0')}Z';

    final expenseFormValues = {
      'expenseDate': formattedDate,
      'title': title,
      'category': category,
      'amount': amountCents,
      'paidBy': paidBy,
      'paidFor': paidFor.map((s) => s.toJson()).toList(),
      'splitMode': splitMode.wireValue,
      'saveDefaultSplittingOptions': false,
      'isReimbursement': isReimbursement,
      'documents': [],
      'notes': notes,
    };

    final uri = Uri.parse('$baseUrl/api/trpc/groups.expenses.create?batch=1');
    final body = {
      '0': {
        'json': {
          'groupId': groupId,
          'expenseFormValues': expenseFormValues,
          'participantId': 'None',
        },
        'meta': {
          'values': {
            'expenseFormValues.expenseDate': ['Date']
          }
        },
      }
    };
    final res = await _http.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    final data = _unwrapBatch(jsonDecode(res.body));
    // groups.expenses.create's success payload shape varies by Spliit
    // version; this app only needs to know the write succeeded; the local
    // (client-generated) id already assigned to the pending row stands in
    // for the server id until the next full fetchExpenses() reconciles it.
    return data is Map<String, dynamic> ? (data['expenseId'] as String? ?? '') : '';
  }

  /// Applies a full group-settings edit -- name, currency, and the
  /// complete participant list -- in one `groups.update` mutation.
  /// Spliit has no per-field or per-participant update endpoint; the web
  /// app's own settings form edits everything together, and this
  /// mirrors that shape.
  ///
  /// Ported from splitwise2spliit's spliit_api.py (`add_participant`),
  /// which was verified end-to-end against a live server and documents
  /// the server's actual `updateGroup()` behavior: a submitted
  /// participant with an [Participant.id] is matched against an
  /// existing row and updated -- a client-made-up id that matches
  /// nothing is a silent no-op, not an error; one with an *empty* id is
  /// created and assigned a real id by the server; and, per that same
  /// source (not independently re-verified here), one that existed
  /// before but is missing from this call is deleted. So callers must
  /// always pass the *complete* desired participant list: existing
  /// participants with their real ids, new ones with `id: ''`, and
  /// removed ones simply left out.
  ///
  /// Like [createExpense], this only confirms the request didn't come
  /// back with an embedded tRPC error -- the success payload shape
  /// isn't relied on. Callers that need the real ids the server assigns
  /// to newly-created participants should follow up with [fetchGroup].
  Future<void> updateGroup({
    required String groupId,
    required String name,
    required String currency,
    required List<Participant> participants,
  }) async {
    final groupFormValues = {
      'name': name,
      'currency': currency,
      'participants': participants
          .map((p) => p.id.isEmpty ? {'name': p.name} : {'id': p.id, 'name': p.name})
          .toList(),
    };

    final uri = Uri.parse('$baseUrl/api/trpc/groups.update?batch=1');
    final body = {
      '0': {
        'json': {
          'groupId': groupId,
          'groupFormValues': groupFormValues,
        },
      }
    };
    final res = await _http.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    _unwrapBatch(jsonDecode(res.body)); // throws SpliitApiException on an embedded error
  }
}

class SpliitApiException implements Exception {
  final int statusCode;
  final String body;
  SpliitApiException(this.statusCode, this.body);

  @override
  String toString() => 'SpliitApiException($statusCode): $body';
}
