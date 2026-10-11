import 'package:flutter/material.dart';

import '../models/group.dart';
import '../theme.dart';

/// Each participant's color in a group (#207), fixed rather than hashed
/// so no two share one while there are colors left: the seven colors of
/// [monogramPalette] after emerald, by name, starting over past seven.
/// You are emerald, the app's own accent, in place of yours; the others
/// keep theirs whoever you are, so picking someone else in "Who are
/// you?" recolors only the two of you (#218, Kenneth).
Map<String, Color> participantColors(List<Participant> participants, String? activeUserId) {
  final others = monogramPalette.sublist(1);
  final byName = participantsByName(participants);
  return {
    for (final (i, p) in byName.indexed)
      p.id: p.id == activeUserId ? monogramPalette[0] : others[i % others.length],
  };
}
