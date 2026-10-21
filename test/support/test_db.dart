import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';

AppDatabase? _open;

/// An in-memory database for a screen under test, closed when the test
/// ends (#333). A second one in the same test first unmounts the screen
/// and closes the one before it: drift warns about two open at once, as
/// two on one file would race, and the warning stays on to catch that in
/// the app. Close only through here; a second close would skew drift's
/// count and hide later warnings.
Future<AppDatabase> openTestDb(WidgetTester tester) async {
  final previous = _open;
  if (previous != null) {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    _open = null;
    await previous.close();
  }
  final db = _open = AppDatabase(NativeDatabase.memory());
  addTearDown(() async {
    if (!identical(_open, db)) return;
    _open = null;
    await db.close();
  });
  return db;
}
