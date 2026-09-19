import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/spliit_client.dart';
import 'db/app_database.dart';
import 'db/connection.dart';
import 'l10n/app_localizations.dart';
import 'screens/group_list_screen.dart';
import 'screens/group_screen.dart';
import 'services/settings_service.dart';
import 'sync/outbox.dart';
import 'theme.dart';

void main() {
  runApp(const Spliit2GoApp());
}

class Spliit2GoApp extends StatelessWidget {
  const Spliit2GoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'spliit2go',
      // i18n phase 1 (issue #37/#48): infra only -- app_en.arb is the
      // only shipped locale for now, so this doesn't change what any
      // user sees yet. The delegates/supportedLocales still have to be
      // wired up here regardless, since AppLocalizations.of(context)
      // (used at every replaced Text() call site) resolves through
      // whatever Localizations ancestor MaterialApp installs.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Issue #25: MaterialApp's own default `themeMode` is already
      // ThemeMode.system -- the app was never actually opted into
      // "always light," that setting simply had nothing to switch to.
      // Without a `darkTheme`, MaterialApp falls back to `theme` even
      // when the system is in dark mode (see WidgetsApp's theme
      // resolution: it's `darkTheme ?? theme`, never a synthesized dark
      // variant of `theme`), so this was silently always-light
      // regardless of the device setting. [spliit2goDarkTheme] (see
      // theme.dart) is the whole fix; `themeMode: system` is written
      // out explicitly below only so that intent doesn't rely on a
      // reader already knowing MaterialApp's default.
      theme: spliit2goLightTheme,
      darkTheme: spliit2goDarkTheme,
      themeMode: ThemeMode.system,
      home: const _Root(),
      // Issue #24: modern Android (edge-to-edge is mandatory starting
      // with API 35, and Flutter's default template doesn't opt out of
      // it) draws the app behind the status bar *and* the bottom
      // gesture/nav bar. Scaffold only insets its AppBar for the top
      // status bar automatically (AppBar already extends its own color
      // up behind the translucent status bar and lays its content below
      // it) -- it does nothing for the bottom, so plain body content
      // (a form's Save button at the bottom of a ListView, a bottom
      // sheet's last row) was left sitting right behind the bottom
      // gesture/nav bar, exactly the "save button under bottom nav bar"
      // symptom reported.
      //
      // top: false here is deliberate, not an oversight: an *unscoped*
      // SafeArea insets from the top too, which double-insets below
      // AppBar's own handling and leaves a blank gap the app's
      // background color, not the AppBar's, shows through -- confirmed
      // on a real device after the first version of this fix (see the
      // issue). Bottom-only avoids that while still fixing the actual
      // complaint. Wrapping the whole app once here, rather than adding
      // it to every individual screen, insets every route's bottom
      // content uniformly, including screens added later. A descendant
      // SafeArea (e.g. the currency/category picker bottom sheets)
      // still works correctly nested inside this one: SafeArea consumes
      // the padding it applies, so there's no double-inset there.
      //
      // The nav bar itself still showed up deep black regardless of
      // theme even after setting systemNavigationBarColor via
      // AnnotatedRegion<SystemUiOverlayStyle> -- confirmed on-device.
      // The reason: starting with apps that target API 35,
      // Window.setNavigationBarColor (what that overlay style call
      // turns into) is a documented no-op -- edge-to-edge means the
      // system nav bar is *always* transparent now, and it's the app's
      // own job to paint content behind it, not ask the system to tint
      // it. What was actually showing through as "deep black" was the
      // plain Android window background (styles.xml's LaunchTheme),
      // because SafeArea's Padding stops our Scaffold from painting
      // into that strip at all -- there was nothing Flutter-side there
      // to show through the now-transparent bar. The fix is this
      // Container: a full-bleed backdrop in the *current* theme's own
      // scaffoldBackgroundColor, painted underneath the SafeArea-inset
      // content, so the strip behind the bar shows our theme's color
      // instead of the native window background. This is the standard
      // fix for this exact class of bug on API 35+; keeping
      // spliit2goSystemUiOverlayStyle's color/contrast fields too is
      // just belt-and-suspenders for whatever pre-35 devices are still
      // out there, where Window.setNavigationBarColor still works.
      //
      // Theme.of(context) here resolves to whichever of
      // theme/darkTheme MaterialApp picked for the current system
      // brightness, so both the backdrop and the overlay style stay
      // correct across light and dark mode (issue #25) without needing
      // their own brightness plumbing.
      builder: spliit2goAppBuilder,
    );
  }
}

/// The `MaterialApp.builder` above, pulled out as a top-level function
/// so its behavior (the Container backdrop + AnnotatedRegion, both
/// explained in the doc comment above) is unit-testable directly with a
/// throwaway `home`, without booting the real app's `_Root` and its
/// live AppDatabase/sqlite connection.
Widget spliit2goAppBuilder(BuildContext context, Widget? child) {
  final theme = Theme.of(context);
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: spliit2goSystemUiOverlayStyle(theme),
    child: Container(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(top: false, child: child!),
    ),
  );
}

/// Always shows GroupListScreen as the app's true root -- see
/// decisions/multi-group-design.md's revision after
/// github.com/sharneng/spliit2go/issues/12: GroupScreen is a detail view
/// *below* the list, not the other way around, so it's reached by
/// pushing onto the list (giving it a normal, always-valid back arrow
/// back to it) rather than the list sometimes being what you back out
/// of. "Launch straight into the last-used group" (decision 3) is done
/// as an automatic push right after the list mounts, once there's a
/// one-time migration (folding a legacy single-group install's
/// SettingsService values into the new AppDatabase-backed joined-groups
/// list) out of the way. Owns the AppDatabase instance (the one
/// long-lived object every screen shares) -- there's no DI framework,
/// just one screen graph.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  final _db = AppDatabase(openConnection());

  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _migrateLegacySingleGroup();
    final last = await _db.mostRecentlyOpenedGroup();
    if (!mounted) return;
    setState(() => _checked = true);
    // Deferred to a post-frame callback: GroupListScreen (this build's
    // `home`) has to actually exist and be mounted, with a Navigator
    // above it, before anything can be pushed onto it.
    if (last != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openGroup(last);
      });
    }
  }

  /// Pushes [row] as a GroupScreen on top of the (always-present)
  /// GroupListScreen -- the launch fast path above, and shared by
  /// GroupListScreen's own row taps rather than duplicating this.
  Future<void> _openGroup(GroupRow row) async {
    await _db.recordGroupOpened(row.id, serverUrl: row.serverUrl);
    if (!mounted) return;
    final client = SpliitClient(baseUrl: row.serverUrl);
    final outbox = Outbox(_db, client, groupId: row.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupScreen(client: client, db: _db, outbox: outbox, groupId: row.id),
      ),
    );
  }

  /// One-time migration for an install that predates multi-group
  /// support: folds the old single global server_url/group_id/
  /// active_user_id (SettingsService) into this group's now-per-group
  /// AppDatabase.Groups row, and seeds the new device-wide
  /// defaultActiveUserName from that participant's cached name so
  /// groups joined from here on auto-match without prompting. A no-op
  /// for any install that never had those legacy keys -- including
  /// every fresh install from here on -- and idempotent (checks
  /// `serverUrl.isNotEmpty` so it only runs once even though it's
  /// called on every launch). See decisions/multi-group-design.md.
  Future<void> _migrateLegacySingleGroup() async {
    final settings = SettingsService();
    final legacyGroupId = await settings.legacyGroupId();
    final legacyServerUrl = await settings.legacyServerUrl();
    if (legacyGroupId == null || legacyServerUrl == null) return;

    final row = await _db.groupRow(legacyGroupId);
    if (row == null || row.serverUrl.isNotEmpty) {
      // Either this group was never successfully cached before the
      // update (rare -- would mean the old app never got past a first,
      // failed sync -- nothing to migrate, the user just rejoins), or
      // this has already run in an earlier launch.
      return;
    }

    await _db.recordGroupOpened(legacyGroupId, serverUrl: legacyServerUrl);

    final legacyActiveUserId = await settings.legacyActiveUserId();
    if (legacyActiveUserId == null) return;
    await _db.setActiveParticipant(legacyGroupId, legacyActiveUserId);

    final cachedGroup = await _db.cachedGroup(legacyGroupId);
    String? name;
    for (final p in cachedGroup?.participants ?? const []) {
      if (p.id == legacyActiveUserId) {
        name = p.name;
        break;
      }
    }
    if (name != null) {
      await settings.setDefaultActiveUserName(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return GroupListScreen(db: _db);
  }
}
