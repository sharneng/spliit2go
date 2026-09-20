import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/services/date_span_calculator.dart';
import 'package:spliit2go/services/group_list_order.dart';
import 'package:spliit2go/services/settings_service.dart';
import 'package:spliit2go/widgets/group_monogram.dart';

void main() {
  test('all four orders are descending, missing dates last, ties stable',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final id in ['a', 'b', 'c']) {
      await db.cacheGroup(Group(
          id: id,
          name: id,
          currency: r'$',
          participants: [],
          createdAt: id == 'c' ? null : DateTime.utc(2026, id == 'a' ? 1 : 2)));
      await db.recordGroupOpened(id,
          serverUrl: 'https://example.test',
          at: DateTime.utc(2026, id == 'a' ? 3 : 1));
    }
    final rows = await db.allJoinedGroups();
    final spans = {
      'a': DateSpan(first: DateTime(2026, 1), last: DateTime(2026, 5)),
      'b': DateSpan(first: DateTime(2026, 2), last: DateTime(2026, 4)),
    };
    for (final entry in {
      GroupListSort.firstExpense: ['b', 'a', 'c'],
      GroupListSort.lastExpense: ['a', 'b', 'c'],
      GroupListSort.created: ['b', 'a', 'c'],
      GroupListSort.lastOpened: ['a', 'b', 'c'],
    }.entries) {
      final ordered = [...rows.reversed]
        ..sort((a, b) => compareGroupRows(a, b, entry.key, spans));
      expect(ordered.map((g) => g.id), entry.value);
    }
  });

  test('sort persists and unknown preferences use last opened', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService().setGroupListSort(GroupListSort.created.name);
    expect(groupListSortFromTag(await SettingsService().groupListSort()),
        GroupListSort.created);
    expect(groupListSortFromTag('future'), GroupListSort.lastOpened);
  });

  test('monogram matches iOS recorded FNV colors and Unicode initials', () {
    expect(groupColorIndex('participant-1'), 0);
    expect(groupColorIndex('participant-2'), 1);
    expect(groupColorIndex('ana'), 5);
    expect(groupColorIndex('bruno'), 7);
    expect(groupInitials('  Sébastien  Castiel '), 'SC');
    expect(groupInitials('👨‍👩‍👧‍👦 trip'), '👨‍👩‍👧‍👦T');
    expect(groupInitials('   '), '');
  });
}
