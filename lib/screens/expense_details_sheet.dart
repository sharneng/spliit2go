import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/category_names.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/active_user.dart';
import '../services/expense_shares.dart';
import '../sync/outbox.dart';
import '../utils/date_format.dart';
import '../utils/money.dart';
import '../widgets/category_icon.dart';
import 'expense_screen.dart';
import '../services/error_reporting.dart';
import '../widgets/error_message.dart';

/// What tapping an expense does, from both the expense list and the
/// Activity tab (issue #90): a bottom sheet showing the expense's details,
/// with editing as an explicit action rather than the default.
///
/// Reads the local cache, so it works offline, and watches that one row
/// ([AppDatabase.watchExpense]) so it never shows details that are no
/// longer current: it updates when the row changes and closes when the
/// row goes away (deleted, discarded, or re-keyed to the server's id when
/// a pending expense syncs).
///
/// With [fetchIfMissing] -- the Activity tab, whose entries can point at
/// an expense this device hasn't cached yet -- a cache miss fetches the
/// expense from the server instead, showing loading, "no longer
/// available" and connection problems inside the sheet.
///
/// What the sheet offers depends on the expense's state:
/// - **Synced:** Edit and Delete, both disabled while the phone reports
///   no connection, with the reason shown in the sheet. Edit fetches the
///   expense fresh first (Spliit has no edit-conflict protection, see
///   docs/decisions/expense-form-completion.md), then opens the existing
///   form. Delete asks for confirmation, deletes on the server for the
///   whole group, and only then removes the local copy.
/// - **Pending:** view only, until it reaches the server.
/// - **Sync failed:** Retry, or Discard this device's copy (the expense
///   never reached the server). Both are local, so both work offline.
///
/// Returns true when something changed that the caller should sync or
/// refresh for: an edit was saved, the expense was deleted, a failed one
/// was requeued, or one was discarded.
Future<bool> showExpenseDetails(
  BuildContext context, {
  required String expenseId,
  required Group group,
  required AppDatabase db,
  required SpliitClient client,
  required Outbox outbox,
  List<Category> categories = const [],
  String? activeUserId,
  bool fetchIfMissing = false,
  @visibleForTesting Stream<bool>? connectivity,
}) async {
  final action = await showModalBottomSheet<_SheetAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ExpenseDetailsSheet(
      expenseId: expenseId,
      group: group,
      db: db,
      client: client,
      categories: categories,
      activeUserId: activeUserId,
      fetchIfMissing: fetchIfMissing,
      connectivity: connectivity ?? _deviceOnline(),
    ),
  );
  if (!context.mounted) return false;
  switch (action) {
    case _Edit(:final fresh):
      final edited = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ExpenseScreen(
            client: client,
            db: db,
            outbox: outbox,
            group: group,
            existingExpense: fresh,
          ),
        ),
      );
      return edited == true;
    case _Changed():
      return true;
    case null:
      return false;
  }
}

/// Whether the phone has a network connection, now and as it changes.
/// Ends without a value where connectivity_plus has no platform support
/// (widget tests, a misconfigured platform): the sheet then treats the
/// connection as unknown and lets Edit find out for itself.
Stream<bool> _deviceOnline() async* {
  final connectivity = Connectivity();
  bool online(List<ConnectivityResult> results) =>
      !results.contains(ConnectivityResult.none);
  try {
    yield online(await connectivity.checkConnectivity());
  } catch (e, st) {
    // No plugin here (widget tests) is expected; anything else isn't.
    if (!isMissingPlugin(e)) {
      ErrorReporter.instance.report(e, st, operation: 'Checking connectivity');
    }
    return;
  }
  yield* connectivity.onConnectivityChanged.map(online);
}

sealed class _SheetAction {
  const _SheetAction();
}

/// Close the sheet and open the edit form with [fresh], the server's
/// current copy.
class _Edit extends _SheetAction {
  final Expense fresh;
  const _Edit(this.fresh);
}

/// A change the caller should sync or refresh for (delete, retry or
/// discard).
class _Changed extends _SheetAction {
  const _Changed();
}

enum _LoadProblem { notFound, failed }

enum _ServerAction { edit, delete }

class _ExpenseDetailsSheet extends StatefulWidget {
  final String expenseId;
  final Group group;
  final AppDatabase db;
  final SpliitClient client;
  final List<Category> categories;
  final String? activeUserId;
  final bool fetchIfMissing;
  final Stream<bool> connectivity;

  const _ExpenseDetailsSheet({
    required this.expenseId,
    required this.group,
    required this.db,
    required this.client,
    required this.categories,
    required this.activeUserId,
    required this.fetchIfMissing,
    required this.connectivity,
  });

  @override
  State<_ExpenseDetailsSheet> createState() => _ExpenseDetailsSheetState();
}

class _ExpenseDetailsSheetState extends State<_ExpenseDetailsSheet> {
  StreamSubscription<ExpenseRow?>? _rowSub;
  StreamSubscription<bool>? _onlineSub;

  Expense? _expense;
  bool _loading = true;
  _LoadProblem? _problem;

  /// Diagnostics for an unexpected load or action failure (#119 review).
  String? _problemDiagnostics;

  /// Whether the cache has held this expense since the sheet opened. Once
  /// it has, the row disappearing means the expense is gone.
  bool _cached = false;

  /// Null until the platform reports: unknown, so Edit stays enabled.
  bool? _online;

  /// An Edit fetch, Delete, Retry or Discard is in flight. Every action
  /// is disabled meanwhile, so none can run twice.
  bool _busy = false;

  /// Which server action is running, for its button's spinner.
  _ServerAction? _running;

  /// Why the last Edit or Delete didn't go through, shown under them.
  String? _actionError;
  String? _actionDiagnostics;

  /// An Activity cache-miss fetch is in flight.
  bool _fetching = false;

  /// Set once the sheet starts closing through [_close].
  bool _closing = false;

  /// A close asked for while the Delete confirmation covered the sheet,
  /// with the action to close with. Popping then would close the dialog
  /// instead, so it waits for the confirmation to end (see [_delete]).
  bool _closeDeferred = false;
  _SheetAction? _deferredAction;

  /// What to close with when the row disappears because of our own
  /// Delete or Discard, rather than a plain dismissal.
  _SheetAction? _closeWith;

  @override
  void initState() {
    super.initState();
    _rowSub = widget.db.watchExpense(widget.expenseId).listen(_onRow);
    _onlineSub = widget.connectivity.listen(
      (online) {
        if (mounted) setState(() => _online = online);
      },
      onError: (Object e, StackTrace st) =>
          ErrorReporter.instance.report(e, st, operation: 'Watching connectivity'),
    );
  }

  @override
  void dispose() {
    _rowSub?.cancel();
    _onlineSub?.cancel();
    super.dispose();
  }

  void _onRow(ExpenseRow? row) {
    if (!mounted || _closing) return;
    if (row != null) {
      _cached = true;
      // Back after going away mid-confirmation: nothing to close after all.
      _closeDeferred = false;
      setState(() {
        _expense = widget.db.rowToExpense(row);
        _loading = false;
        _problem = null;
      });
    } else if (_cached) {
      _close(_closeWith);
    } else if (_expense != null || _fetching) {
      // Showing (or loading) the server's copy of an uncached expense.
      // Drift re-emits on every write to the table, not just this row, so
      // this is a refresh or sync elsewhere, not a reason to fetch again.
    } else if (widget.fetchIfMissing) {
      _fetchFromServer();
    } else {
      setState(() {
        _loading = false;
        _problem = _LoadProblem.notFound;
      });
    }
  }

  /// Pops the sheet with [action], unless it's already closing -- and
  /// only ever the sheet, never the route above or below it:
  /// - **Dismissed** (a barrier tap, swipe or Back popped its route
  ///   directly): the sheet stays mounted through its closing animation,
  ///   so a late Edit fetch, Retry or row change can still land here. Its
  ///   route is no longer active, and popping anyway would take the screen
  ///   underneath with it (PR #95 review). [mounted] alone can't tell.
  /// - **Covered** by the Delete confirmation: still active, just not
  ///   current, and popping would close the dialog instead. The close
  ///   waits for the confirmation to end (PR #96 review).
  void _close([_SheetAction? action]) {
    if (_closing) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) {
      _closing = true;
      return;
    }
    if (!route.isCurrent) {
      _closeDeferred = true;
      _deferredAction = action;
      return;
    }
    _closing = true;
    Navigator.of(context).pop(action);
  }

  /// Activity cache miss: load the expense from the server instead. It's
  /// shown but not cached -- the next refresh caches it.
  Future<void> _fetchFromServer() async {
    setState(() {
      _loading = true;
      _fetching = true;
      _problem = null;
      _problemDiagnostics = null;
    });
    try {
      final expense = await widget.client
          .fetchExpense(groupId: widget.group.id, expenseId: widget.expenseId);
      if (!mounted || _cached) return;
      setState(() {
        _expense = expense;
        _loading = false;
      });
    } catch (e, st) {
      // Deleted meanwhile is expected; anything else goes through the
      // shared policy (logged and detailed only if unexpected).
      final notFound = e is SpliitApiException && e.isNotFound;
      final error = notFound
          ? null
          : ErrorReporter.instance.report(e, st, operation: 'Loading expense ${widget.expenseId}');
      if (!mounted || _cached) return;
      setState(() {
        _loading = false;
        _problem = notFound ? _LoadProblem.notFound : _LoadProblem.failed;
        _problemDiagnostics = error?.diagnostics;
      });
    } finally {
      _fetching = false;
    }
  }

  Future<void> _edit() async {
    setState(() {
      _busy = true;
      _running = _ServerAction.edit;
      _actionError = null;
      _actionDiagnostics = null;
    });
    try {
      final fresh = await widget.client
          .fetchExpense(groupId: widget.group.id, expenseId: widget.expenseId);
      if (mounted) _close(_Edit(fresh));
    } catch (e, st) {
      // Only a connection problem is a connection problem (#119 review);
      // anything else unexpected is logged, with details.
      final notFound = e is SpliitApiException && e.isNotFound;
      final error = notFound
          ? null
          : ErrorReporter.instance.report(e, st, operation: 'Fetching expense ${widget.expenseId} to edit');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _running = null;
        _actionError = switch (error?.kind) {
          null => context.l10n.expenseDetailsNotFound,
          ErrorKind.connection => context.l10n.groupScreenEditNeedsConnection,
          _ => context.l10n.expenseDetailsEditFailed,
        };
        _actionDiagnostics = error?.diagnostics;
      });
    }
  }

  Future<void> _delete(Expense e) async {
    final confirmed = await _confirmDelete(e.title);
    if (!mounted) return;
    if (_closeDeferred) {
      // The expense went away while the confirmation was up (a refresh
      // found it deleted). Close now, and don't send a delete for it.
      _closeDeferred = false;
      _close(_deferredAction);
      return;
    }
    if (!confirmed) return;
    setState(() {
      _busy = true;
      _running = _ServerAction.delete;
      _actionError = null;
      _actionDiagnostics = null;
    });
    final (:deleted, :error) = await _deleteOnServer();
    if (deleted) {
      // Only now, with the server confirming, does the local copy go --
      // even if the sheet was dismissed meanwhile, or the expense list
      // would keep showing it until some later refresh. Its disappearance
      // closes an open sheet (see _onRow); one never cached (opened from
      // Activity) is closed below.
      _closeWith = const _Changed();
      await widget.db.removeDeletedExpense(widget.group.id, widget.expenseId);
      if (mounted) _close(const _Changed());
      return;
    }
    if (!mounted) return;
    // Nothing changed locally: the cached copy stays, as it should.
    setState(() {
      _busy = false;
      _running = null;
      _actionError = error?.isUnexpected == true
          ? context.l10n.expenseDeleteFailedUnexpected
          : context.l10n.expenseDeleteFailed;
      _actionDiagnostics = error?.diagnostics;
    });
  }

  /// Deletes the expense on the server; true once it's gone. A failure is
  /// double-checked, because upstream errors when deleting an expense
  /// that's already gone -- a retry after a lost response, or someone
  /// else deleting it first (see [SpliitClient.deleteExpense]). If the
  /// server then says it doesn't exist, the delete worked. When it
  /// didn't, [error] is the delete's own failure, reported through the
  /// shared policy (#119 review); the check's failure is reported too.
  Future<({bool deleted, ReportedError? error})> _deleteOnServer() async {
    try {
      await widget.client.deleteExpense(
        groupId: widget.group.id,
        expenseId: widget.expenseId,
        participantId: await _activityParticipant(),
      );
      return (deleted: true, error: null);
    } catch (deleteError, deleteStack) {
      try {
        await widget.client
            .fetchExpense(groupId: widget.group.id, expenseId: widget.expenseId);
        // Still there: the delete really failed.
      } catch (e, st) {
        if (e is SpliitApiException && e.isNotFound) return (deleted: true, error: null);
        ErrorReporter.instance
            .report(e, st, operation: 'Checking whether expense ${widget.expenseId} was deleted');
      }
      return (
        deleted: false,
        error: ErrorReporter.instance.report(deleteError, deleteStack,
            operation: 'Deleting expense ${widget.expenseId}'),
      );
    }
  }

  /// Who to credit in Spliit's activity log (issue #92), the same way
  /// ExpenseScreen does for an edit.
  Future<String?> _activityParticipant() async {
    final row = await widget.db.groupRow(widget.group.id);
    return activityParticipantId(
      storedActiveParticipantId: row?.activeParticipantId,
      participants: widget.group.participants,
    );
  }

  /// Asks before deleting: it's for everyone in the group and can't be
  /// undone. Adaptive, like leaving a group (GroupListScreen).
  Future<bool> _confirmDelete(String title) async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = dialogContext.l10n;
        final platform = Theme.of(dialogContext).platform;
        final cupertino = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
        return AlertDialog.adaptive(
          title: Text(l10n.expenseDeleteConfirmTitle),
          content: Text(l10n.expenseDeleteConfirmBody(title)),
          actions: cupertino
              ? [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(l10n.commonCancel)),
                  CupertinoDialogAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(l10n.commonDelete)),
                ]
              : [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(l10n.commonCancel)),
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: TextButton.styleFrom(
                          foregroundColor: Theme.of(dialogContext).colorScheme.error),
                      child: Text(l10n.commonDelete)),
                ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    await widget.db.retrySyncFailure(widget.expenseId);
    if (mounted) _close(const _Changed());
  }

  Future<void> _discard() async {
    setState(() => _busy = true);
    // The row's own disappearance closes the sheet (see _onRow); this
    // just makes that close report the change.
    _closeWith = const _Changed();
    final discarded = await widget.db.deleteFailedExpense(widget.expenseId);
    // Nothing matched: the expense stopped being a failed one while the
    // sheet was open (a retry and sync elsewhere). The row watch already
    // shows its new state.
    if (!discarded && mounted) {
      setState(() {
        _busy = false;
        _closeWith = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: _content(context),
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    final expense = _expense;
    if (expense != null) return _details(context, expense);
    if (_loading) {
      return const [
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final l10n = context.l10n;
    final message = switch (_problem) {
      _LoadProblem.notFound => l10n.expenseDetailsNotFound,
      _ when _online == false => l10n.activityOpenNeedsConnection,
      _ => l10n.expenseDetailsLoadFailed,
    };
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: _problemDiagnostics == null
            ? Text(message, textAlign: TextAlign.center)
            : ErrorMessage(message, diagnostics: _problemDiagnostics, textAlign: TextAlign.center),
      ),
      if (_problem == _LoadProblem.failed)
        Center(
          child: TextButton(onPressed: _fetchFromServer, child: Text(l10n.commonRetry)),
        ),
    ];
  }

  List<Widget> _details(BuildContext context, Expense e) {
    final l10n = context.l10n;
    final locale = context.appLocale;
    final theme = Theme.of(context);
    final currency = widget.group.currency;
    final shares = expenseShareCents(e);
    final known = widget.categories.where((c) => c.id == e.category).firstOrNull;
    final originalAmount = e.originalAmountCents;
    final originalCurrency = e.originalCurrency;

    return [
      Row(
        children: [
          CategoryIconGlyph(category: known, size: 40),
          const SizedBox(width: 12),
          Expanded(child: Text(e.title, style: theme.textTheme.titleLarge)),
        ],
      ),
      const SizedBox(height: 12),
      Text(formatMoney(e.amountCents, currency, locale: locale),
          style: theme.textTheme.headlineSmall),
      if (originalAmount != null && originalCurrency != null)
        Text(
          l10n.expenseDetailsOriginalAmount(
              formatMoney(originalAmount, _symbolFor(originalCurrency), locale: locale)),
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ..._badges(context, e),
      const SizedBox(height: 12),
      ..._actions(context, e),
      const Divider(height: 32),
      _info(context, Icons.calendar_today_outlined, l10n.expenseDateLabel,
          formatDate(e.date, locale: locale)),
      _info(context, Icons.category_outlined, l10n.expenseCategoryLabel,
          localizedCategoryLabel(context, e.category, known)),
      _info(context, Icons.person_outline, l10n.expensePaidByLabel, _name(e.paidBy)),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(child: Text(l10n.expensePaidForHeading, style: theme.textTheme.titleSmall)),
          Text(_splitLabel(context, e.splitMode),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
      const SizedBox(height: 4),
      for (final share in e.paidFor)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: Text(_name(share.participantId))),
              const SizedBox(width: 12),
              Text(formatMoney(shares[share.participantId] ?? 0, currency, locale: locale)),
            ],
          ),
        ),
      if (e.notes.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(l10n.expenseNotesLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(e.notes),
      ],
    ];
  }

  List<Widget> _badges(BuildContext context, Expense e) {
    final l10n = context.l10n;
    final labels = [
      if (e.isReimbursement) l10n.expenseDetailsReimbursement,
      switch (e.recurrenceRule) {
        RecurrenceRule.daily => l10n.expenseDetailsRepeatsDaily,
        RecurrenceRule.weekly => l10n.expenseDetailsRepeatsWeekly,
        RecurrenceRule.monthly => l10n.expenseDetailsRepeatsMonthly,
        RecurrenceRule.none => null,
      },
    ].whereType<String>();
    if (labels.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final label in labels)
            Chip(label: Text(label), visualDensity: VisualDensity.compact),
        ],
      ),
    ];
  }

  List<Widget> _actions(BuildContext context, Expense e) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    if (e.syncFailed) {
      return [
        Text(l10n.groupScreenSyncFailureTitle,
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.error)),
        if (e.lastError != null)
          Text(e.lastError!, maxLines: 3, overflow: TextOverflow.ellipsis, style: muted),
        const SizedBox(height: 4),
        Text(l10n.expenseDetailsFailedHint, style: muted),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _retry,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _discard,
              style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.expenseDetailsDiscard),
            ),
          ],
        ),
      ];
    }
    if (e.pending) return [Text(l10n.expenseDetailsPending, style: muted)];
    final offline = _online == false;
    final message = _actionError ?? (offline ? l10n.expenseDetailsNeedsConnection : null);
    Widget icon(_ServerAction action, IconData data) => _running == action
        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(data);
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: _busy || offline ? null : _edit,
            icon: icon(_ServerAction.edit, Icons.edit_outlined),
            label: Text(l10n.expenseDetailsEdit),
          ),
          OutlinedButton.icon(
            onPressed: _busy || offline ? null : () => _delete(e),
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            icon: icon(_ServerAction.delete, Icons.delete_outline),
            label: Text(l10n.commonDelete),
          ),
        ],
      ),
      if (message != null) ...[
        const SizedBox(height: 4),
        if (_actionDiagnostics != null)
          ErrorMessage(message, diagnostics: _actionDiagnostics)
        else
          Text(message, style: muted),
      ],
    ];
  }

  Widget _info(BuildContext context, IconData icon, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Text(value, style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A participant's name, marked when it's this device's active user. A
  /// participant no longer in the group reads "Someone", as in Activity.
  String _name(String id) {
    final l10n = context.l10n;
    final participant = widget.group.participants.where((p) => p.id == id).firstOrNull;
    if (participant == null) return l10n.activitySomeone;
    return id == widget.activeUserId ? l10n.expenseDetailsYou(participant.name) : participant.name;
  }

  /// The "paid in" currency's symbol (€ for EUR), or its code when this
  /// app doesn't know it.
  String _symbolFor(String code) {
    final currency = currencyByCode(code);
    return currency.symbol.isEmpty ? code : currency.symbol;
  }

  String _splitLabel(BuildContext context, SplitMode mode) {
    final l10n = context.l10n;
    return switch (mode) {
      SplitMode.evenly => l10n.expenseSplitEvenly,
      SplitMode.byShares => l10n.expenseSplitShares,
      SplitMode.byPercentage => l10n.expenseSplitPercent,
      SplitMode.byAmount => l10n.expenseSplitAmount,
    };
  }
}
