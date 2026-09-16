import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../sync/outbox.dart';
import 'add_expense_screen.dart';

/// The main (and, for now, only) screen: a group's expenses, offline-first.
///
/// On load, shows whatever's cached locally immediately, then tries a live
/// fetch in the background and replaces the cache on success. Pending
/// (offline-added, not yet synced) expenses always show regardless of
/// connectivity, badged as unsynced, since they're never touched by the
/// server-fetch overwrite -- see AppDatabase.replaceServerExpenses.
class GroupScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final String groupId;

  const GroupScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.groupId,
  });

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  Group? _group;
  List<Expense> _expenses = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFromCache();
    _refresh();
    Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) {
        _syncThenRefresh();
      }
    });
  }

  Future<void> _loadFromCache() async {
    final rows = await widget.db.expensesForGroup(widget.groupId);
    if (!mounted) return;
    setState(() => _expenses = rows.map(widget.db.rowToExpense).toList());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final group = await widget.client.fetchGroup(widget.groupId);
      final fresh = await widget.client.fetchExpenses(widget.groupId);
      await widget.db.replaceServerExpenses(widget.groupId, fresh);
      if (!mounted) return;
      setState(() {
        _group = group;
        _error = null;
      });
      await _loadFromCache();
    } catch (e) {
      // Offline or the server's unreachable -- fine, we already loaded
      // whatever's cached. Only surface an error if we have nothing at
      // all to show.
      if (_expenses.isEmpty) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncThenRefresh() async {
    final synced = await widget.outbox.flush();
    if (synced > 0) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_group?.name ?? 'spliit2go')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _body(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _group == null ? null : _openAddExpense,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _body() {
    if (_expenses.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_expenses.isEmpty && _error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Center(child: Text('Couldn\'t reach the server: $_error')),
        ],
      );
    }
    if (_expenses.isEmpty) {
      return const Center(child: Text('No expenses yet.'));
    }
    return ListView.builder(
      itemCount: _expenses.length,
      itemBuilder: (context, i) {
        final e = _expenses[i];
        return ListTile(
          title: Text(e.title),
          subtitle: Text('${e.date.toLocal()}'.split(' ').first),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('\$${(e.amountCents / 100).toStringAsFixed(2)}'),
              if (e.pending)
                const Text('syncing…', style: TextStyle(fontSize: 11)),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openAddExpense() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddExpenseScreen(
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
        ),
      ),
    );
    if (added == true) {
      await _loadFromCache();
      _syncThenRefresh();
    }
  }
}
