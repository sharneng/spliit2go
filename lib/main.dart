import 'package:flutter/material.dart';

void main() {
  runApp(const Spliit2GoApp());
}

class Spliit2GoApp extends StatelessWidget {
  const Spliit2GoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'spliit2go',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const _PlaceholderHome(),
    );
  }
}

/// Scaffold placeholder -- groups list, expense list, and the add-expense
/// flow (wired to SpliitClient + the drift-backed outbox) still need
/// building. See README.md for current status.
class _PlaceholderHome extends StatelessWidget {
  const _PlaceholderHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('spliit2go')),
      body: const Center(child: Text('Nothing here yet.')),
    );
  }
}
