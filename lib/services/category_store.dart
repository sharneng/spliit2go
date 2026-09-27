import 'dart:async';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/category.dart';
import 'error_reporting.dart';

/// Expense categories, available offline (#132).
///
/// A server's list is kept in `CachedCategories` and read again once per
/// app run (or when asked to [refresh] with `force`). Until this device
/// has read a server's list, it's [spliitSeedCategories]: every Spliit
/// instance starts with those, under the same ids.
///
/// A failed read keeps what's there. Offline, that's expected and not
/// logged; anything else is logged once (#119).
class CategoryStore {
  CategoryStore(this.db);

  final AppDatabase db;

  static final _byDb = Expando<CategoryStore>('CategoryStore');

  /// The store for [db], shared by every screen using it.
  static CategoryStore of(AppDatabase db) => _byDb[db] ??= CategoryStore(db);

  /// Servers whose list was read in this run.
  final _read = <String>{};
  final _inFlight = <String, Future<void>>{};

  /// [client]'s server's categories, in its order: the cached list, or
  /// the seeded one until there is one. Follows every change.
  Stream<List<Category>> watch(SpliitClient client) =>
      db.watchCategories(client.baseUrl).map(_orSeeded);

  static List<Category> _orSeeded(List<Category> cached) =>
      cached.isEmpty ? spliitSeedCategories : cached;

  /// [client]'s server's categories as they are now; see [watch].
  Future<List<Category>> current(SpliitClient client) async =>
      _orSeeded(await db.categoriesFor(client.baseUrl));

  /// Reads [client]'s server's list and keeps it, unless it was already
  /// read in this run and [force] isn't set. Never throws: the screens
  /// keep what they show.
  Future<void> refresh(SpliitClient client, {bool force = false}) {
    final server = client.baseUrl;
    if (!force && _read.contains(server)) return Future.value();
    return _inFlight[server] ??= _fetch(client).whenComplete(() {
      _inFlight.remove(server);
    });
  }

  Future<void> _fetch(SpliitClient client) async {
    try {
      final categories = await client.fetchCategories();
      // An empty answer isn't a list to keep: the form always needs at
      // least General.
      if (categories.isNotEmpty) await db.replaceCategories(client.baseUrl, categories);
      _read.add(client.baseUrl);
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Loading categories');
    }
  }
}
