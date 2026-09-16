import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Opens (creating if needed) the on-device SQLite file drift uses for the
/// local cache + outbox. Standard drift-on-Flutter boilerplate -- see
/// https://drift.simonbinder.eu/docs/getting-started/ -- kept in its own
/// file since it's infrastructure, not app logic.
LazyDatabase openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'spliit2go.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
