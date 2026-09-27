import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/category.dart';

// Issue #132: each server's category list, kept offline.
void main() {
  const general = Category(id: 0, name: 'General', grouping: 'Uncategorized');
  const hobbies = Category(id: 44, name: 'Hobbies', grouping: 'Life');
  const groceries = Category(id: 9, name: 'Groceries', grouping: 'Food and Drink');

  List<int> ids(List<Category> cs) => [for (final c in cs) c.id];

  test('a list is replaced whole, kept in its order, per server', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await db.replaceCategories('https://a.test', const [hobbies, general, groceries]);
    await db.replaceCategories('https://b.test', const [general]);
    expect(ids(await db.categoriesFor('https://a.test')), [44, 0, 9]);

    await db.replaceCategories('https://a.test', const [general, groceries]);
    expect(ids(await db.categoriesFor('https://a.test')), [0, 9]);
    expect(ids(await db.categoriesFor('https://b.test')), [0]);
    expect(await db.categoriesFor('https://c.test'), isEmpty);
    final kept = (await db.categoriesFor('https://a.test')).last;
    expect((kept.name, kept.grouping), ('Groceries', 'Food and Drink'));
  });

  test('a version 13 database migrates, with no categories until the next read', () async {
    final dir = await Directory.systemTemp.createTemp('categories-v13-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('DROP TABLE cached_categories');
    await old.customStatement('DROP TABLE receipt_attachments');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipt_download_problem');
    await old.customStatement('PRAGMA user_version = 13');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.categoriesFor('https://spliit.app'), isEmpty);
    await db.replaceCategories('https://spliit.app', const [general, groceries]);
    expect(ids(await db.categoriesFor('https://spliit.app')), [0, 9]);
  });
}
