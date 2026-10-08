import 'dart:convert';
import 'package:flutter/material.dart';
import '../theme.dart';

// Matches spliit-ios MonogramPalette; see THIRD_PARTY_NOTICES.md.
int groupColorIndex(String id) {
  // Only the low three FNV-1a bits affect modulo eight. Keeping those
  // bits avoids platform-dependent integer overflow, including on web.
  var hash = 5;
  for (final byte in utf8.encode(id)) {
    hash = ((hash ^ byte) * 3) & 7;
  }
  return hash;
}

String groupInitials(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .take(2)
    .map((word) => word.characters.first)
    .join()
    .toUpperCase();

class GroupMonogram extends StatelessWidget {
  const GroupMonogram({super.key, required this.id, required this.name});
  final String id;
  final String name;
  @override
  Widget build(BuildContext context) =>
      Monogram(name: name, color: monogramPalette[groupColorIndex(id)]);
}

/// [name]'s initials in white on a [color] circle: a group's in the group
/// list, a participant's in "Who are you?" (#218).
class Monogram extends StatelessWidget {
  const Monogram({super.key, required this.name, required this.color, this.radius = 20});
  final String name;
  final Color color;
  final double radius;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CircleAvatar(
          radius: radius,
          backgroundColor: color,
          foregroundColor: Colors.white,
          child: Text(groupInitials(name),
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontSize: radius * 0.85, fontWeight: FontWeight.w600)),
        ),
      );
}
