import 'package:flutter/material.dart';

import '../theme.dart';

/// The screen with nothing on it (#179), after spliit-ios's `EmptyState`
/// (see THIRD_PARTY_NOTICES.md): art, a bold title, an optional muted
/// description and optional actions.
///
/// Centered when it fits and scrollable when it doesn't, so at the
/// largest text sizes the actions can still be reached. Always
/// scrollable, so a RefreshIndicator around it still works. Inside a
/// list (unbounded height) it's just the column.
class EmptyState extends StatelessWidget {
  /// An icon in a tile tinted with the accent.
  const EmptyState({
    super.key,
    required IconData this.icon,
    required this.title,
    this.description,
    this.actions = const [],
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  }) : logo = false;

  /// The app's logo instead of an icon: for welcome and first run, where
  /// naming the app is the point. Never for an error.
  const EmptyState.logo({
    super.key,
    required this.title,
    this.description,
    this.actions = const [],
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  })  : icon = null,
        logo = true;

  final IconData? icon;
  final bool logo;
  final String title;
  final String? description;
  final List<Widget> actions;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (!constraints.hasBoundedHeight) return _content(context);
      // Centered in the space above the gesture bar, or the group
      // screen's floating bar, not behind it (#197).
      final inset = MediaQuery.paddingOf(context).bottom;
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: keyboardDismissBehavior,
        padding: EdgeInsets.only(bottom: inset),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minWidth: constraints.maxWidth,
              minHeight: (constraints.maxHeight - inset).clamp(0, double.infinity)),
          child: Center(child: _content(context)),
        ),
      );
    });
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _art(context),
          const SizedBox(height: 12),
          Text(title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          if (description != null) ...[
            const SizedBox(height: 8),
            // Long enough to read, short enough to stay a paragraph.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(description!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 16),
            ...actions,
          ],
        ],
      ),
    );
  }

  /// A fixed size, deliberately, as in spliit-ios: a decoration that grew
  /// with the text would push the actions further out of reach.
  Widget _art(BuildContext context) {
    if (logo) {
      return const ExcludeSemantics(
        child: Image(image: AssetImage('assets/spliit2go-logo.png'), height: 60),
      );
    }
    return ExcludeSemantics(
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: SpliitColors.of(context).brandAccentSoft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(icon, size: 30, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
