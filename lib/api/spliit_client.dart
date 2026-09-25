import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/activity.dart';
import '../models/category.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/date_only.dart';
import '../services/error_reporting.dart';

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
/// - Id-shaped fields (group id, participant id, expense id, the
///   pagination cursor) are read leniently -- coerced to a string via
///   [_asId] rather than assumed to already be one. A self-hosted
///   instance running against an older/different Prisma schema for
///   these fields can plausibly send a numeric id where spliit.app
///   sends a cuid string; a bare `as String` cast on that throws
///   `type 'int' is not a subtype of type 'String' in type cast` and
///   takes down the whole group screen (github.com/sharneng/spliit2go/issues/14).
///   Same leniency for `expenseDate` via [_asDateTime], in case a
///   server ever sends an epoch-millis number instead of the ISO
///   string superjson normally produces.
/// Coerces an id-shaped field to a String. Every id in this API is
/// meant to be a string (a Prisma cuid, in spliit.app's own schema),
/// but a self-hosted instance on a different schema/version could
/// plausibly send a numeric one instead -- see the class doc comment
/// and github.com/sharneng/spliit2go/issues/14. Accepting either shape
/// here means an unexpected numeric id becomes a usable (if unusual)
/// string id instead of crashing the whole screen.
String _asId(dynamic value) => value is String ? value : value.toString();

/// Coerces an expense date field to a [DateTime]. Normally an ISO 8601
/// string (superjson's wire format for a JS `Date` when meta isn't
/// consulted -- see the class doc comment), but tolerates a raw
/// epoch-millis number too, in case a server ever sends one.
DateTime _asDateTime(dynamic value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.round(), isUtc: true);
  }
  return DateTime.parse(value as String);
}

/// Coerces `conversionRate` to a [double]. Spliit stores it as a Prisma
/// `Decimal`, which can come back over the wire as a plain number or (via
/// superjson/decimal.js) as a numeric string -- tolerate either rather
/// than assume one.
double _asDouble(dynamic value) => value is num ? value.toDouble() : double.parse(value as String);

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

  /// Fetches group details: name, information, currency, participants.
  Future<Group> fetchGroup(String groupId) async {
    final uri = _trpcUri('groups.get', input: {'groupId': groupId});
    final res = await _http.get(uri);
    _checkOk(res);
    final data = _unwrapBatch(jsonDecode(res.body)) as Map<String, dynamic>;
    // Spliit answers an unknown id with an explicit `{group: null}`, not
    // an error (spliit-web `getGroup` returns null; checked on
    // spliit.app), which used to surface as a type-cast error (issue
    // #118). Only that contract means "not found": a missing or
    // wrong-typed `group` is a malformed response (#119 review).
    final g = data['group'];
    if (g == null && data.containsKey('group')) throw GroupNotFoundException(baseUrl, groupId);
    if (g is! Map<String, dynamic>) {
      throw SpliitResponseFormatException('groups.get: expected a group object, got ${g.runtimeType}');
    }

    return Group(
      id: _asId(g['id']),
      name: g['name'] as String,
      createdAt: DateTime.tryParse(g['createdAt'] as String? ?? ''),
      information: g['information'] as String?,
      currency: g['currency'] as String,
      currencyCode: g['currencyCode'] as String?,
      participants: (g['participants'] as List)
          .map((p) => Participant(
                id: _asId((p as Map<String, dynamic>)['id']),
                name: p['name'] as String,
              ))
          .toList(),
    );
  }

  /// Fetches every expense in the group, following pagination.
  ///
  /// `cursor` is passed through opaquely -- whatever type `nextCursor`
  /// comes back as (a numeric offset on at least one real server; the
  /// splitwise2spliit port this was based on assumed an opaque cuid
  /// string cursor, which was wrong -- see
  /// github.com/sharneng/spliit2go/issues/14) goes right back into the
  /// next request unchanged, rather than being coerced to a String and
  /// then rejected by the server with "expected number, received
  /// string".
  Future<List<Expense>> fetchExpenses(String groupId) async {
    final all = <Expense>[];
    dynamic cursor;
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
          id: _asId(m['id']),
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
          date: dateOnlyFromUtcMidnight(_asDateTime(m['expenseDate'])),
          isReimbursement: m['isReimbursement'] as bool? ?? false,
          recurrenceRule: RecurrenceRuleWire.fromWire(m['recurrenceRule'] as String? ?? 'NONE'),
          originalAmountCents: (m['originalAmount'] as num?)?.round(),
          originalCurrency: m['originalCurrency'] as String?,
          conversionRate: m['conversionRate'] == null ? null : _asDouble(m['conversionRate']),
          createdAt: m['createdAt'] == null ? null : _asDateTime(m['createdAt']),
        ));
      }

      if (data['hasMore'] != true) break;
      cursor = data['nextCursor'];
    }
    return all;
  }

  /// One page of a group's activity log (issue #26), newest first --
  /// mirrors `groups.activities.list`'s own pagination shape exactly
  /// (`cursor`/`limit` in, `activities`/`hasMore`/`nextCursor` out)
  /// rather than following every page the way [fetchExpenses] does,
  /// since this is a "load more" UI, not something cached for offline
  /// use -- see activity_screen.dart.
  Future<ActivityPage> fetchActivities({
    required String groupId,
    int cursor = 0,
    int limit = 20,
  }) async {
    final uri = _trpcUri(
      'groups.activities.list',
      input: {'groupId': groupId, 'cursor': cursor, 'limit': limit},
    );
    final res = await _http.get(uri);
    _checkOk(res);
    final data = _unwrapBatch(jsonDecode(res.body)) as Map<String, dynamic>;

    final activities = (data['activities'] as List).map((raw) {
      final m = raw as Map<String, dynamic>;
      final expenseId = m['expenseId'] == null ? null : _asId(m['expenseId']);
      return Activity(
        id: _asId(m['id']),
        time: _asDateTime(m['time']),
        activityType: ActivityType.fromWire(m['activityType'] as String),
        participantId: m['participantId'] == null ? null : _asId(m['participantId']),
        expenseId: expenseId,
        data: m['data'] as String?,
        // The server includes `expense` only when that expense still
        // exists (see getActivities in spliit-app/spliit's lib/api.ts) --
        // a present expenseId with no matching `expense` means it's
        // since been deleted.
        expenseExists: expenseId != null && m['expense'] != null,
      );
    }).toList();

    return ActivityPage(
      activities: activities,
      hasMore: data['hasMore'] == true,
      nextCursor: (data['nextCursor'] as num).round(),
    );
  }

  /// Fetches a single expense fresh from the server, bypassing the local
  /// cache entirely. Used right before opening the edit screen (issue
  /// #17) to minimize the window between what's shown and what's on the
  /// server -- the server itself has no conflict-prevention (see
  /// updateExpense's doc comment), so this fetch-immediately-before-edit
  /// is the only mitigation available on the client side.
  Future<Expense> fetchExpense({required String groupId, required String expenseId}) async {
    final uri = _trpcUri('groups.expenses.get', input: {'groupId': groupId, 'expenseId': expenseId});
    final res = await _http.get(uri);
    _checkOk(res);
    final data = _unwrapBatch(jsonDecode(res.body)) as Map<String, dynamic>;
    final m = data['expense'] as Map<String, dynamic>;
    return Expense(
      id: _asId(m['id']),
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
      date: dateOnlyFromUtcMidnight(_asDateTime(m['expenseDate'])),
      isReimbursement: m['isReimbursement'] as bool? ?? false,
      recurrenceRule: RecurrenceRuleWire.fromWire(m['recurrenceRule'] as String? ?? 'NONE'),
      originalAmountCents: (m['originalAmount'] as num?)?.round(),
      originalCurrency: m['originalCurrency'] as String?,
      conversionRate: m['conversionRate'] == null ? null : _asDouble(m['conversionRate']),
      createdAt: m['createdAt'] == null ? null : _asDateTime(m['createdAt']),
    );
  }

  /// Fetches the full category list, in the server's own order (already
  /// grouped -- same [Category.grouping] entries are adjacent), including
  /// each category's [Category.grouping] for the grouped/searchable
  /// picker added in issue #19.
  Future<List<Category>> fetchCategories() async {
    final uri = _trpcUri('categories.list');
    final res = await _http.get(uri);
    _checkOk(res);
    final data = _unwrapBatch(jsonDecode(res.body)) as Map<String, dynamic>;
    return (data['categories'] as List)
        .map((c) => Category.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// Builds the `expenseFormValues` payload shared by
  /// `groups.expenses.create` and `groups.expenses.update` -- the two
  /// mutations take an identical form shape (verified against
  /// src/lib/schemas.ts' expenseFormSchema upstream), so both
  /// [createExpense] and [updateExpense] go through this one place
  /// rather than duplicating the field list.
  ///
  /// [amountCents] and each [paidFor] share are in cents. For
  /// [SplitMode.evenly], shares is just a nonzero weight (1 per person is
  /// the common case); for [SplitMode.byAmount] it's the exact cents owed.
  ///
  /// [originalAmountCents]/[originalCurrency]/[conversionRate] are the
  /// "Paid in" fields -- all three null together for an expense entered
  /// directly in the group's own currency. `saveDefaultSplittingOptions`
  /// is a form-only action flag on Spliit's side (there's no persisted
  /// column for it on the Expense model) -- it's still sent on every
  /// call, just never round-tripped back into our own [Expense] model.
  /// "Attach documents" is deliberately not exposed here yet -- it needs
  /// Spliit's presigned-S3-upload flow (next-s3-upload), a substantial
  /// separate subsystem this app has no offline-queueing story for yet;
  /// `documents` is always sent empty.
  Map<String, dynamic> _expenseFormValues({
    required String title,
    required int amountCents,
    required String paidBy,
    required List<ExpenseShare> paidFor,
    required SplitMode splitMode,
    required int category,
    required String notes,
    required DateTime date,
    required bool isReimbursement,
    required RecurrenceRule recurrenceRule,
    required bool saveDefaultSplittingOptions,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
  }) {
    // date-only, not a timestamp -- see date_only.dart's doc comment.
    // dateOnlyToUtcMidnight() always lands on an exact UTC midnight, so
    // toIso8601String() already comes out as e.g.
    // "2026-09-16T00:00:00.000Z" with no extra formatting needed.
    final formattedDate = dateOnlyToUtcMidnight(date).toIso8601String();

    return {
      'expenseDate': formattedDate,
      'title': title,
      'category': category,
      'amount': amountCents,
      'paidBy': paidBy,
      'paidFor': paidFor.map((s) => s.toJson()).toList(),
      'splitMode': splitMode.wireValue,
      'saveDefaultSplittingOptions': saveDefaultSplittingOptions,
      'isReimbursement': isReimbursement,
      'documents': [],
      'notes': notes,
      'recurrenceRule': recurrenceRule.wireValue,
      if (originalAmountCents != null) 'originalAmount': originalAmountCents,
      if (originalCurrency != null) 'originalCurrency': originalCurrency,
      if (conversionRate != null) 'conversionRate': conversionRate,
    };
  }

  /// The `participantId` Spliit records in its activity log for a
  /// create/update (issue #92) -- who made the change. Spliit-web sends
  /// the group's active user, or the literal `'None'` when the user
  /// declined to pick one; this does the same, so a null [participantId]
  /// (no active user on this device) is logged unattributed exactly as
  /// before. Upstream stores it as a plain string, not a foreign key, so
  /// an id for someone who has since left the group can't fail the write.
  static String _activityParticipant(String? participantId) =>
      participantId ?? 'None';

  /// Creates an expense (or, with [isReimbursement], a settlement payment)
  /// on the server. Called either immediately (online) or later by the
  /// outbox once connectivity returns (see lib/sync/outbox.dart) -- this
  /// method itself has no offline logic. [participantId] is who to credit
  /// in Spliit's activity log (see [_activityParticipant]).
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
    RecurrenceRule recurrenceRule = RecurrenceRule.none,
    bool saveDefaultSplittingOptions = false,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
    String? participantId,
  }) async {
    final expenseFormValues = _expenseFormValues(
      title: title,
      amountCents: amountCents,
      paidBy: paidBy,
      paidFor: paidFor,
      splitMode: splitMode,
      category: category,
      notes: notes,
      date: date ?? DateTime.now(),
      isReimbursement: isReimbursement,
      recurrenceRule: recurrenceRule,
      saveDefaultSplittingOptions: saveDefaultSplittingOptions,
      originalAmountCents: originalAmountCents,
      originalCurrency: originalCurrency,
      conversionRate: conversionRate,
    );

    final uri = Uri.parse('$baseUrl/api/trpc/groups.expenses.create?batch=1');
    final body = {
      '0': {
        'json': {
          'groupId': groupId,
          'expenseFormValues': expenseFormValues,
          'participantId': _activityParticipant(participantId),
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

  /// Updates an existing expense on the server (issue #17). Online-only
  /// by design -- unlike [createExpense], there's no offline queueing
  /// path for edits (see decisions/mobile-platform.md on the app's
  /// view+add-only offline scope).
  ///
  /// IMPORTANT, per explicit ask on issue #17: Spliit's server has **no
  /// optimistic-concurrency or conflict-prevention mechanism** for
  /// expense edits. Verified directly against upstream source -- the
  /// `Expense` Prisma model has no `updatedAt`/version column at all, and
  /// `groups.expenses.update`'s input schema (groupId, expenseId,
  /// expenseFormValues, participantId?) carries no last-modified/version
  /// parameter either. The write is genuinely last-write-wins server
  /// side: if two people edit the same expense around the same time, the
  /// second `updateExpense` call simply overwrites the first with no
  /// error and no warning from the server. The only mitigation available
  /// on this client is minimizing the staleness window -- callers should
  /// fetch the expense fresh with [fetchExpense] immediately before
  /// showing the edit form, rather than editing a possibly-stale locally
  /// cached copy -- not a real guarantee.
  ///
  /// [participantId] is who to credit in Spliit's activity log (see
  /// [_activityParticipant]).
  Future<String> updateExpense({
    required String groupId,
    required String expenseId,
    required String title,
    required int amountCents,
    required String paidBy,
    required List<ExpenseShare> paidFor,
    SplitMode splitMode = SplitMode.evenly,
    int category = 0,
    String notes = '',
    DateTime? date,
    bool isReimbursement = false,
    RecurrenceRule recurrenceRule = RecurrenceRule.none,
    bool saveDefaultSplittingOptions = false,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
    String? participantId,
  }) async {
    final expenseFormValues = _expenseFormValues(
      title: title,
      amountCents: amountCents,
      paidBy: paidBy,
      paidFor: paidFor,
      splitMode: splitMode,
      category: category,
      notes: notes,
      date: date ?? DateTime.now(),
      isReimbursement: isReimbursement,
      recurrenceRule: recurrenceRule,
      saveDefaultSplittingOptions: saveDefaultSplittingOptions,
      originalAmountCents: originalAmountCents,
      originalCurrency: originalCurrency,
      conversionRate: conversionRate,
    );

    final uri = Uri.parse('$baseUrl/api/trpc/groups.expenses.update?batch=1');
    final body = {
      '0': {
        'json': {
          'groupId': groupId,
          'expenseId': expenseId,
          'expenseFormValues': expenseFormValues,
          'participantId': _activityParticipant(participantId),
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
    return data is Map<String, dynamic> ? (data['expenseId'] as String? ?? expenseId) : expenseId;
  }

  /// Deletes an expense on the server (issue #90), for everyone in the
  /// group. Online-only, like [updateExpense]; [participantId] is who to
  /// credit in Spliit's activity log (see [_activityParticipant]).
  ///
  /// Verified against upstream (`delete.procedure.ts` and `deleteExpense`
  /// in `src/lib/api.ts`, `cc79621`): it takes `{expenseId, groupId,
  /// participantId?}` and returns `{}`. It logs the DELETE_EXPENSE
  /// activity *before* deleting, and the deletion throws if the expense
  /// is already gone, outside any transaction. So a delete whose response
  /// was lost errors if retried even though the expense is gone (and
  /// logs a second "deleted" entry) -- callers should check with
  /// [fetchExpense] before treating a failure as real.
  Future<void> deleteExpense({
    required String groupId,
    required String expenseId,
    String? participantId,
  }) async {
    final uri = Uri.parse('$baseUrl/api/trpc/groups.expenses.delete?batch=1');
    final body = {
      '0': {
        'json': {
          'groupId': groupId,
          'expenseId': expenseId,
          'participantId': _activityParticipant(participantId),
        },
      }
    };
    final res = await _http.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    _unwrapBatch(jsonDecode(res.body));
  }

  /// Applies a full group-settings edit -- name, information, currency
  /// (both the display [currency] symbol and, when it's one of Spliit's
  /// 34 known currencies, its [currencyCode] -- see
  /// models/currency.dart), and the complete participant list -- in one
  /// `groups.update` mutation. Spliit has no per-field or
  /// per-participant update endpoint; the web app's own settings form
  /// edits everything together, and this mirrors that shape.
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
    String? information,
    required String currency,
    String? currencyCode,
    required List<Participant> participants,
  }) async {
    final groupFormValues = _groupFormValues(
      name: name,
      information: information,
      currency: currency,
      currencyCode: currencyCode,
      participants: participants,
    );

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

  /// Creates a group on this server (issue #115): `groups.create`, which
  /// takes the same `groupFormValues` as [updateGroup] and returns the new
  /// group's id (spliit-web `src/trpc/routers/groups/create.procedure.ts`
  /// @ cc796210). Every participant is new, so only names are sent; the
  /// server assigns all ids, which [fetchGroup] then returns.
  Future<String> createGroup({
    required String name,
    String? information,
    required String currency,
    String? currencyCode,
    required List<String> participantNames,
  }) async {
    final uri = Uri.parse('$baseUrl/api/trpc/groups.create?batch=1');
    final body = {
      '0': {
        'json': {
          'groupFormValues': _groupFormValues(
            name: name,
            information: information,
            currency: currency,
            currencyCode: currencyCode,
            participants: [for (final n in participantNames) Participant(id: '', name: n)],
          ),
        },
      }
    };
    final res = await _http.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    final data = _unwrapBatch(jsonDecode(res.body)) as Map<String, dynamic>;
    return _asId(data['groupId']);
  }

  /// The server's `groupFormSchema` shape, shared by [createGroup] and
  /// [updateGroup].
  Map<String, dynamic> _groupFormValues({
    required String name,
    String? information,
    required String currency,
    String? currencyCode,
    required List<Participant> participants,
  }) =>
      {
        'name': name,
        'information': information ?? '',
        'currency': currency,
        // The server's groupFormSchema wants a 3-letter code or '' (not
        // null) for "no code" -- see z.union([z.string().length(3)...,
        // z.literal('')]) in schemas.ts.
        'currencyCode': currencyCode ?? '',
        'participants': participants
            .map((p) => p.id.isEmpty ? {'name': p.name} : {'id': p.id, 'name': p.name})
            .toList(),
      };
}

/// One page of [SpliitClient.fetchActivities].
class ActivityPage {
  final List<Activity> activities;
  final bool hasMore;
  final int nextCursor;

  const ActivityPage({required this.activities, required this.hasMore, required this.nextCursor});
}

/// The server has no group with this id: [SpliitClient.fetchGroup] got
/// `{group: null}` (issue #118). Usually a mistyped or mangled link.
class GroupNotFoundException implements UserError {
  final String serverUrl;
  final String groupId;
  GroupNotFoundException(this.serverUrl, this.groupId);

  @override
  String toString() => 'GroupNotFoundException: no group "$groupId" on $serverUrl';
}

class SpliitApiException implements Exception {
  final int statusCode;
  final String body;
  SpliitApiException(this.statusCode, this.body);

  /// Whether the server said the thing asked for doesn't exist -- e.g.
  /// `groups.expenses.get` for an expense someone has deleted, which
  /// upstream throws as tRPC `NOT_FOUND` (issue #90). tRPC reports that as
  /// HTTP 404, or as an error embedded in a 200 batch response; both
  /// carry `NOT_FOUND` / JSON-RPC code -32004 in the body.
  bool get isNotFound =>
      statusCode == 404 || body.contains('NOT_FOUND') || body.contains('-32004');

  @override
  String toString() => 'SpliitApiException($statusCode): $body';
}
