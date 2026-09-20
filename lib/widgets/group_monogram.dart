import 'dart:convert';
import 'package:flutter/material.dart';

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
  static const colors = <Color>[
    Color(0xff059669),
    Color(0xff0891B2),
    Color(0xff6366F1),
    Color(0xffBE185D),
    Color(0xffEA580C),
    Color(0xffCA8A04),
    Color(0xff4D7C0F),
    Color(0xff7C3AED),
  ];
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CircleAvatar(
          radius: 20,
          backgroundColor: colors[groupColorIndex(id)],
          foregroundColor: Colors.white,
          child: Text(groupInitials(name),
              textScaler: TextScaler.noScaling,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        ),
      );
}
