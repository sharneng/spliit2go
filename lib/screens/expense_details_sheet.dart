import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
import '../widgets/money.dart';
import '../widgets/category_icon.dart';
import 'expense_screen.dart';
import '../services/error_reporting.dart';
import '../services/receipt_cache.dart';
import '../widgets/error_message.dart';
import '../widgets/receipts.dart';
import '../utils/haptics.dart';
import '../widgets/grouped_section.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/expense_list.dart' show participantColors;
import '../widgets/group_monogram.dart';
import '../widgets/top_bar_buttons.dart';
import '../theme.dart';

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
  @visibleForTesting DateTime Function() now = DateTime.now,
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
      now: now,
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
            activeUserId: activeUserId,
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

  /// Today, for whether the summary's date needs its year.
  final DateTime Function() now;

  const _ExpenseDetailsSheet({
    required this.expenseId,
    required this.group,
    required this.db,
    required this.client,
    required this.categories,
    required this.activeUserId,
    required this.fetchIfMissing,
    required this.connectivity,
    required this.now,
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

  /// For a split by shares or percentages: each person's amount in place
  /// of their share (#226). Shares by default, as the split was entered.
  bool _showAmounts = false;

  /// Which server action is running, for its button's spinner.
  _ServerAction? _running;

  /// Why the last Edit or Delete didn't go through, shown under them.
  String? _actionError;
  String? _actionDiagnostics;

  /// An Activity cache-miss fetch is in flight.
  bool _fetching = false;

  /// Set once the sheet starts closing through [_close].
  bool _closing = false;

  /// Receipts (#123). The cache stores an expense's documents once it's
  /// been read in full; the list only gives their count. [_storedDocs] is
  /// what the cache holds, [_fetchedDocs] what this sheet just read.
  StreamSubscription<List<ExpenseDocument>>? _docSub;
  List<ExpenseDocument>? _storedDocs;
  List<ExpenseDocument>? _fetchedDocs;

  /// Documents are read at most once per open, and again after a
  /// connection failure once the phone is back online.
  bool _docsFetchStarted = false;
  bool _docsOffline = false;
  String? _docsDiagnostics;

  /// A pending expense's photos not uploaded yet (#124), shown from this
  /// device.
  StreamSubscription<List<ReceiptAttachmentRow>>? _attachmentSub;
  List<ReceiptAttachmentRow> _attachments = const [];

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
    _docSub = widget.db.watchExpenseDocuments(widget.expenseId).listen((docs) {
      if (!mounted) return;
      setState(() => _storedDocs = docs);
      _maybeFetchDocuments();
    });
    _attachmentSub = widget.db.watchAttachments(widget.expenseId).listen((rows) {
      if (mounted) setState(() => _attachments = rows);
    });
    _onlineSub = widget.connectivity.listen(
      (online) {
        if (!mounted) return;
        setState(() => _online = online);
        if (online && _docsOffline) {
          // Back online: read the documents that couldn't be read offline.
          _docsFetchStarted = false;
          _docsOffline = false;
        }
        _maybeFetchDocuments();
      },
      onError: (Object e, StackTrace st) =>
          ErrorReporter.instance.report(e, st, operation: 'Watching connectivity'),
    );
  }

  @override
  void dispose() {
    _rowSub?.cancel();
    _docSub?.cancel();
    _attachmentSub?.cancel();
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
      _maybeFetchDocuments();
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

  /// The expense's documents, or null while they aren't known: a cached
  /// expense's stored ones count only while they match the list's count.
  List<ExpenseDocument>? _documentsOf(Expense e) {
    // Uncached (read from the server), or pending (uploaded, not synced):
    // the expense carries its own.
    if (!_cached || e.pending) return e.documents;
    if (_fetchedDocs != null) return _fetchedDocs;
    final stored = _storedDocs;
    return stored != null && stored.length == e.documentCount ? stored : null;
  }

  /// Reads a cached expense's documents once per open while online, and
  /// stores them (#123). Stored ones show meanwhile, but a matching count
  /// doesn't mean they're current: a receipt can be swapped on the web
  /// with the count unchanged (#130 review), so they're always checked.
  Future<void> _maybeFetchDocuments() async {
    final e = _expense;
    if (e == null || !_cached || e.pending || e.documentCount == 0) return;
    if (_docsFetchStarted || _online == false || _storedDocs == null) return;
    _docsFetchStarted = true;
    try {
      final fresh =
          await widget.client.fetchExpense(groupId: widget.group.id, expenseId: widget.expenseId);
      await widget.db.cacheExpenseDocuments(widget.group.id, widget.expenseId, fresh.documents);
      if (!mounted) return;
      setState(() => _fetchedDocs = fresh.documents);
    } catch (err, st) {
      // Deleted meanwhile: the row watch closes the sheet.
      if (err is SpliitApiException && err.isNotFound) return;
      final error = ErrorReporter.instance
          .report(err, st, operation: 'Loading receipts of expense ${widget.expenseId}');
      if (!mounted) return;
      setState(() {
        _docsOffline = error.kind == ErrorKind.connection;
        // With stored ones showing, a failed check is only logged.
        if (_documentsOf(e) == null) _docsDiagnostics = error.diagnostics;
      });
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
      unawaited(Haptics.deleted());
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

  /// Retry, without the photos that didn't upload (#124): they're
  /// removed from this phone, which has their only copy, so it asks.
  Future<void> _retryWithoutReceipts() async {
    final l10n = context.l10n;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog.adaptive(
        title: Text(l10n.expenseDetailsSyncWithoutReceiptsTitle),
        content: Text(l10n.expenseDetailsSyncWithoutReceiptsBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false), child: Text(l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
              child: Text(l10n.expenseDetailsSyncWithoutReceipts)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await widget.db.retrySyncFailure(widget.expenseId, withoutReceipts: true);
    if (mounted) _close(const _Changed());
  }

  Future<void> _discard() async {
    setState(() => _busy = true);
    // The row's own disappearance closes the sheet (see _onRow); this
    // just makes that close report the change.
    _closeWith = const _Changed();
    final discarded = await widget.db.deleteFailedExpense(widget.expenseId);
    if (discarded) unawaited(Haptics.deleted());
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
        padding: withBottomInset(context, const EdgeInsets.fromLTRB(20, 0, 20, 24)),
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
    final digits = widget.group.decimalDigits;
    final shares = expenseShareCents(e);
    final known = widget.categories.where((c) => c.id == e.category).firstOrNull;
    final originalAmount = e.originalAmountCents;
    final originalCurrency = e.originalCurrency;

    final amount = formatMoney(e.amountCents, currency, decimalDigits: digits, locale: locale);
    final original = originalAmount != null && originalCurrency != null
        ? l10n.expenseDetailsOriginalAmount(
            _withCode(originalCurrency,
                formatMoney(originalAmount, _symbolFor(originalCurrency),
                    decimalDigits: currencyByCode(originalCurrency).decimalDigits, locale: locale)))
        : null;
    final colors = participantColors(widget.group.participants, widget.activeUserId);
    final hasShares = e.splitMode == SplitMode.byShares || e.splitMode == SplitMode.byPercentage;

    return [
      // The sheet's own top bar (#226): the category, the status, the
      // buttons. Beside the title, the buttons squeezed a long one.
      _topBar(context, e, known),
      const SizedBox(height: 8),
      // What the top bar's status means, in one place under it (#226).
      ..._status(context, e),
      // The title, the amount and what it was originally are read as one:
      // "Dinner, $90.00" (#226). The title has the full width.
      Semantics(
          label: [e.title, amount, if (original != null) original].join(', '),
          excludeSemantics: true,
          child: Text(e.title,
              style: theme.textTheme.titleLarge?.copyWith(
                  // A settlement's title italic, as in its row (#224).
                  fontStyle: e.isSettlement ? FontStyle.italic : null))),
      const SizedBox(height: 12),
      ExcludeSemantics(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Money(amount, size: MoneySize.hero, isSettlement: e.isSettlement),
          if (original != null)
            // Real information, so in the text color, not dimmed (#226).
            Text(original, style: theme.textTheme.bodyMedium),
        ]),
      ),
      const SizedBox(height: 20),
      GroupedSection(
        margin: _sectionMargin,
        children: [
          Padding(padding: const EdgeInsets.all(16), child: _summary(context, e, known)),
        ],
      ),
      // Paid for one person, the sentence names them (#247).
      if (_onlyRecipient(e) == null)
      GroupedSection(
        margin: _sectionMargin,
        caption: l10n.expensePaidForHeading,
        // In line with the amounts in the card, as the caption is with the
        // names (#226): the caption's own end padding is 8, the card's 16.
        captionTrailing: Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          // The link over the split method when both don't fit (large text).
          child: Wrap(spacing: 12, alignment: WrapAlignment.end, children: [
            if (hasShares)
              Semantics(
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _showAmounts = !_showAmounts),
                  child: Text(
                      _showAmounts ? l10n.expenseDetailsHideAmounts : l10n.expenseDetailsShowAmounts,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary)),
                ),
              ),
            // How it was split: information, in the text color (#226).
            Text(_splitLabel(context, e.splitMode), style: theme.textTheme.bodyMedium),
          ]),
        ),
        // Past the monogram, under the name.
        dividerIndent: 56,
        children: [
          for (final share in e.paidFor)
            GroupedRow(
              leading: Monogram(
                  name: _participantName(share.participantId),
                  color: colors[share.participantId] ?? monogramPalette.first,
                  radius: 12),
              // One line: the share, as the split was entered, or the
              // amount it comes to (#226).
              title: Text(_name(share.participantId)),
              trailing: switch (_shareLabel(context, e.splitMode, share)) {
                // In the amounts' digits, as an amount without its currency.
                final label? when !_showAmounts => Money(label),
                _ => Money(formatMoney(shares[share.participantId] ?? 0, currency,
                    decimalDigits: digits, locale: locale)),
              },
            ),
        ],
      ),
      if (e.notes.isNotEmpty)
        GroupedSection(
          margin: _sectionMargin,
          caption: l10n.expenseNotesLabel,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(e.notes),
            ),
          ],
        ),
      if (e.documentCount > 0 || (_documentsOf(e)?.isNotEmpty ?? false) || _attachments.isNotEmpty) ...[
        ReceiptsSection(
          cache: ReceiptCache.of(widget.db),
          groupId: widget.group.id,
          count: _documentsOf(e)?.length ?? e.documentCount,
          documents: _documentsOf(e),
          online: _docsOffline ? false : _online,
          loadDiagnostics: _docsDiagnostics,
          pending: _attachments,
        ),
      ],
    ];
  }

  /// The details of the top bar's status, under it: why the sync failed
  /// and what the buttons do, what offline or pending means, a failed
  /// edit or delete. Nothing when all's well.
  List<Widget> _status(BuildContext context, Expense e) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final lines = <Widget>[
      if (e.syncFailed) ...[
        if (e.lastError != null)
          Text(e.lastError!, maxLines: 3, overflow: TextOverflow.ellipsis, style: muted),
        _withIcons(context, muted,
            (mark) => l10n.expenseDetailsFailedHint(mark(_retryIcon), mark(_discardIcon))),
        if (_attachments.isNotEmpty)
          _withIcons(context, muted,
              (mark) => l10n.expenseDetailsReceiptsNotUploaded(mark(_syncWithoutReceiptsIcon))),
      ] else if (e.pending)
        Text(l10n.expenseDetailsPending, style: muted)
      else ...[
        if (_online == false) Text(l10n.expenseDetailsNeedsConnection, style: muted),
        if (_actionError case final message?)
          _actionDiagnostics != null
              ? ErrorMessage(message, diagnostics: _actionDiagnostics)
              : Text(message, style: muted),
      ],
    ];
    if (lines.isEmpty) return const [];
    return [
      for (var i = 0; i < lines.length; i++) ...[if (i > 0) const SizedBox(height: 4), lines[i]],
      const SizedBox(height: 12),
    ];
  }

  static const _retryIcon = Icons.refresh;
  static const _discardIcon = Icons.delete_outline;
  static const _syncWithoutReceiptsIcon = Icons.sync;

  /// A message naming the top bar's buttons with their icons drawn in it
  /// (#226): "Retry ⟳ to send it again". [fill] fills the translation's
  /// placeholders with whatever [mark] returns for each icon.
  Widget _withIcons(BuildContext context, TextStyle? style,
      String Function(String Function(IconData icon) mark) fill) {
    final error = Theme.of(context).colorScheme.error;
    final icons = <String, IconData>{};
    // Private-use characters no translation contains.
    final text = fill((icon) {
      final mark = String.fromCharCode(0xF0020 + icons.length);
      icons[mark] = icon;
      return mark;
    });
    final size = (style?.fontSize ?? 14) * 1.2;
    final spans = <InlineSpan>[];
    text.splitMapJoin(RegExp(icons.keys.map(RegExp.escape).join('|')), onMatch: (m) {
      final icon = icons[m[0]!]!;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Icon(icon, size: size, color: icon == _discardIcon ? error : style?.color),
      ));
      return '';
    }, onNonMatch: (t) {
      spans.add(TextSpan(text: t));
      return '';
    });
    return Text.rich(TextSpan(children: spans), style: style);
  }

  /// The sheet's top bar (#226), as an app bar's: the category icon
  /// leading, a short status ("Sync failed", "No connection") as its
  /// title, and the buttons for the expense's state as its actions.
  Widget _topBar(BuildContext context, Expense e, Category? known) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // Short, at a title's size; what it means is under the bar.
    final title = theme.textTheme.titleLarge;
    final muted = title?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final (String? message, TextStyle? style, List<Widget> buttons) = switch (e) {
      Expense(syncFailed: true) => (
          l10n.expenseDetailsStatusSyncFailed,
          title?.copyWith(color: theme.colorScheme.error),
          [
            // Discard first, Retry at the end: the main action rightmost.
            IconButton(
              tooltip: l10n.expenseDetailsDiscard,
              onPressed: _busy ? null : _discard,
              color: theme.colorScheme.error,
              icon: const Icon(_discardIcon),
            ),
            if (_attachments.isNotEmpty)
              IconButton(
                tooltip: l10n.expenseDetailsSyncWithoutReceipts,
                onPressed: _busy ? null : _retryWithoutReceipts,
                icon: const Icon(_syncWithoutReceiptsIcon),
              ),
            IconButton(
              tooltip: l10n.commonRetry,
              onPressed: _busy ? null : _retry,
              icon: const Icon(_retryIcon),
            ),
          ],
        ),
      Expense(pending: true) => (l10n.expenseDetailsStatusPending, muted, const <Widget>[]),
      _ => (
          _online == false ? l10n.expenseDetailsStatusOffline : null,
          muted,
          _actionButtons(context, e),
        ),
    };
    // The category icon at the start, as a top bar's leading button; the
    // status in all the room between it and the buttons, from the start.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: TopBarButtons.size),
      child: Row(children: [
        // A settlement's banknote is on the sheet's own color, so it
        // gets the buttons' card to stand on; a category's color does.
        e.isSettlement
            ? topBarCard(
                context,
                SizedBox.square(
                  dimension: TopBarButtons.size,
                  // As the glyph draws it, without its circle.
                  child: Icon(LucideIcons.banknote,
                      size: TopBarButtons.size * 0.55, color: theme.colorScheme.primary),
                ))
            : CategoryIconGlyph(category: known, size: TopBarButtons.size),
        const SizedBox(width: 12),
        Expanded(
          child: message == null
              ? const SizedBox.shrink()
              // One line, shrunk rather than wrapped where it's long.
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(message, style: style, maxLines: 1)),
        ),
        if (buttons.isNotEmpty) ...[
          const SizedBox(width: 8),
          TopBarButtons(padding: EdgeInsets.zero, children: buttons),
        ],
      ]),
    );
  }

  /// Edit and delete, as icons on a capsule (#226); off while offline or
  /// busy, a spinner in place of the one running.
  List<Widget> _actionButtons(BuildContext context, Expense e) {
    final l10n = context.l10n;
    final off = _busy || _online == false;
    Widget icon(_ServerAction action, IconData data) => _running == action
        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(data);
    // Delete first, Edit at the end: the main action rightmost.
    return [
      IconButton(
        tooltip: l10n.commonDelete,
        onPressed: off ? null : () => _delete(e),
        color: Theme.of(context).colorScheme.error,
        icon: icon(_ServerAction.delete, Icons.delete_outline),
      ),
      IconButton(
        tooltip: l10n.expenseDetailsEdit,
        onPressed: off ? null : _edit,
        icon: icon(_ServerAction.edit, Icons.edit_outlined),
      ),
    ];
  }

  /// "Paid by Ken on Sep 12 under Groceries" (#226): the first card's
  /// three rows as one sentence, its fixed words in the secondary color so
  /// the names, date and category stand out. The language's own template,
  /// its placeholders found by filling them with markers. Paid for one
  /// person, the sentence names them in place of the list (#247): "for
  /// Bea", or "to Bea" for a settlement.
  Widget _summary(BuildContext context, Expense e, Category? known) {
    final l10n = context.l10n;
    final locale = context.regionalDateLocale;
    final theme = Theme.of(context);
    final payer = e.paidBy == widget.activeUserId
        ? l10n.expenseDetailsPayerYou
        : _participantName(e.paidBy);
    final date = formatDate(e.date,
        locale: locale, withYear: !isWithinTenMonths(e.date, now: widget.now()));
    final category = e.isSettlement
        ? l10n.expenseDetailsSettlement
        : localizedCategoryLabel(context, e.category, known);
    final only = _onlyRecipient(e);
    final recipient = only == null
        ? null
        : only == e.paidBy
            ? (only == widget.activeUserId ? l10n.expenseDetailsYourself : l10n.expenseDetailsThemselves)
            : only == widget.activeUserId
                ? l10n.expenseDetailsRecipientYou
                : _participantName(only);
    final frequency = switch (e.recurrenceRule) {
      RecurrenceRule.daily => l10n.expenseDetailsFrequencyDaily,
      RecurrenceRule.weekly => l10n.expenseDetailsFrequencyWeekly,
      RecurrenceRule.monthly => l10n.expenseDetailsFrequencyMonthly,
      RecurrenceRule.none => null,
    };
    // Private-use characters no translation contains.
    const marks = ['\u{F0000}', '\u{F0001}', '\u{F0002}', '\u{F0003}', '\u{F0005}'];
    final values = [payer, date, category, frequency ?? '', recipient ?? ''];
    final (p, d, c, f, r) = (marks[0], marks[1], marks[2], marks[3], marks[4]);
    final template = switch ((e.isSettlement, recipient != null)) {
          (false, false) => l10n.expenseDetailsSummary(p, d, c),
          (false, true) => l10n.expenseDetailsSummaryFor(p, r, d, c),
          (true, false) => l10n.expenseDetailsSummarySettlement(p, d, c),
          (true, true) => l10n.expenseDetailsSummarySettlementTo(p, r, d, c),
        } +
        (frequency == null ? '' : l10n.expenseDetailsRepeats(f));
    // Then your part, as the list row's arrow says it (#226): "You lent
    // $41.00", the amount in Balances' colors.
    const money = '\u{F0004}';
    final part = _yourPart(e);
    final String? partTemplate = switch (part) {
      null => null,
      (cents: 0, lent: _) => l10n.expenseDetailsNotInvolved,
      // A settlement's only part: what you were paid back.
      (cents: _, lent: _) when e.isSettlement => l10n.expenseDetailsYouReceived(money),
      (cents: _, lent: true) => l10n.expenseDetailsYouLent(money),
      (cents: _, lent: false) => l10n.expenseDetailsYouOwe(money),
    };
    final styled = <String, (String, TextStyle?)>{
      for (var i = 0; i < values.length; i++) marks[i]: (values[i], null),
      if (part != null && part.cents > 0)
        money: (
          formatMoney(part.cents, widget.group.currency,
              decimalDigits: widget.group.decimalDigits, locale: context.appLocale),
          e.isSettlement
              // In the emerald of its banknote, italic as its amount.
              ? Money.styleOf(context, isSettlement: true)
                  ?.copyWith(color: Theme.of(context).colorScheme.primary)
              : Money.styleOf(context, sign: part.lent ? MoneySign.positive : MoneySign.negative),
        ),
    };
    final fixed = TextStyle(color: SpliitColors.of(context).secondaryContent);
    final spans = <TextSpan>[];
    (partTemplate == null ? template : l10n.expenseDetailsSentences(template, partTemplate))
        .splitMapJoin(RegExp(styled.keys.join('|')), onMatch: (m) {
      final (value, style) = styled[m[0]!]!;
      spans.add(TextSpan(text: value, style: style));
      return '';
    }, onNonMatch: (text) {
      if (text.isNotEmpty) spans.add(TextSpan(text: text, style: fixed));
      return '';
    });
    return Text.rich(TextSpan(children: spans), style: theme.textTheme.bodyLarge);
  }

  /// The one person [e] was paid for, whom the sentence names in place of
  /// the Paid for list (#247); none when it was several.
  static String? _onlyRecipient(Expense e) => e.paidFor.length == 1 ? e.paidFor.single.participantId : null;

  /// The active user's part, as the list row has it ([lentOrOwed]), and
  /// 0 cents when they're not in it at all. For a settlement, what they
  /// were paid back; none when they paid it, as the sentence says so.
  ({int cents, bool lent})? _yourPart(Expense e) {
    final me = widget.activeUserId;
    if (me == null) return null;
    if (e.paidBy != me && !e.paidFor.any((s) => s.participantId == me)) {
      return (cents: 0, lent: false);
    }
    if (!e.isSettlement) return lentOrOwed(e, me);
    if (e.paidBy == me) return null;
    return (cents: expenseShareCents(e)[me] ?? 0, lent: false);
  }

  /// A person's part of a split by shares or percentages, shown in place
  /// of their amount until "Show amounts" (#226); none for an even split
  /// or exact amounts, whose amount says it all. Both are stored times 100, so a percentage keeps its two
  /// decimals (66.67%, 0.01%), as the form takes them (#236 review).
  String? _shareLabel(BuildContext context, SplitMode mode, ExpenseShare share) =>
      switch (mode) {
        // The heading already says Shares: just the number.
        SplitMode.byShares =>
          NumberFormat.decimalPattern(context.appLocale.toString()).format(share.shares / 100),
        // Always two decimals, so a column of them lines up (#226).
        SplitMode.byPercentage => (NumberFormat.percentPattern(context.appLocale.toString())
              ..minimumFractionDigits = 2
              ..maximumFractionDigits = 2)
            .format(share.shares / 10000),
        _ => null,
      };

  /// The sheet already has its own side padding.
  static const _sectionMargin = EdgeInsets.only(bottom: 20);

  /// A participant's name, marked when it's this device's active user. A
  /// participant no longer in the group reads "Someone", as in Activity.
  String _name(String id) {
    final l10n = context.l10n;
    final participant = widget.group.participants.where((p) => p.id == id).firstOrNull;
    if (participant == null) return l10n.activitySomeone;
    return id == widget.activeUserId ? l10n.expenseDetailsYou(participant.name) : participant.name;
  }

  /// A participant's name alone, or "Someone".
  String _participantName(String id) =>
      widget.group.participants.where((p) => p.id == id).firstOrNull?.name ??
      context.l10n.activitySomeone;

  /// [amount] after its currency's code, "JPY ¥20,000": ¥ alone could be
  /// yen or yuan, $ any dollar. Once when the symbol is the code.
  String _withCode(String code, String amount) =>
      amount.contains(code) ? amount : '$code $amount';

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
