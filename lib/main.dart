import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/spliit_client.dart';
import 'db/app_database.dart';
import 'db/connection.dart';
import 'l10n/app_localizations.dart';
import 'screens/group_list_screen.dart';
import 'screens/group_screen.dart';
import 'screens/join_group_screen.dart';
import 'services/group_url.dart';
import 'services/settings_service.dart';
import 'services/app_settings.dart';
import 'sync/outbox.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final links = AppLinks();
  final settings = await AppSettings.load(SettingsService());
  runApp(Spliit2GoApp(
      settings: settings,
      home: AppRoot(
        links: links.uriLinkStream,
        initialLink: links.getInitialLink(),
      )));
}

class Spliit2GoApp extends StatelessWidget {
  const Spliit2GoApp({super.key, required this.settings, this.home});

  final AppSettings settings;

  /// Allows embedding a screen without opening the production database.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return AppSettingsScope(
      notifier: settings,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          title: 'Spliit2Go',
          // Lets GroupListScreen hear about routes popped back to it
          // that weren't pushed by its own _openGroup -- e.g. _Root's
          // own auto-open-last-group push right below -- so it can
          // refresh a stale date span (issue #57).
          navigatorObservers: [groupListRouteObserver],
          // i18n (issues #37/#48/#51): AppLocalizations.of(context) (used
          // at every Text() call site) resolves through whatever
          // Localizations ancestor MaterialApp installs from these
          // delegates and supportedLocales -- the latter generated from
          // every lib/l10n/app_*.arb (en, fr, zh).
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Issue #51: the explicit language override from App settings;
          // null (the "System default" choice) lets Flutter resolve the
          // device locale against supportedLocales, falling back to the
          // first supported locale (en). Because this MaterialApp is
          // rebuilt whenever [settings] notifies (see the ListenableBuilder
          // above), changing the override re-localizes the whole running
          // app -- text, and every formatter that reads
          // Localizations.localeOf(context) -- with no restart.
          locale: settings.locale,
          theme: spliit2goLightTheme,
          darkTheme: spliit2goDarkTheme,
          themeMode: settings.themeMode,
          home: home ?? const AppRoot(),
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
        ),
      ),
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
class AppRoot extends StatefulWidget {
  const AppRoot(
      {super.key, this.db, this.links, this.initialLink, this.clientFactory});

  final AppDatabase? db;
  final Stream<Uri>? links;
  final Future<Uri?>? initialLink;
  final SpliitClient Function(String)? clientFactory;

  @override
  State<AppRoot> createState() => _RootState();
}

class _RootState extends State<AppRoot> {
  late final _db = widget.db ?? AppDatabase(openConnection());
  StreamSubscription<Uri>? _linkSubscription;
  final _pendingLinks = <Uri>[];
  String? _activeLink;
  bool _readyForLinks = false;

  String? _linkKey(Uri uri) {
    // External intents are narrower than manually pasted self-hosted URLs.
    if (uri.scheme != 'https' ||
        uri.host != 'spliit.app' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        !uri.path.startsWith('/groups/')) {
      return null;
    }
    final parsed = parseGroupUrl(uri.toString());
    return parsed?.groupId;
  }

  void _receiveLink(Uri uri) {
    final key = _linkKey(uri);
    if (key == null ||
        key == _activeLink ||
        _pendingLinks.any((link) => _linkKey(link) == key)) {
      return;
    }
    _pendingLinks.add(uri);
    if (_readyForLinks) unawaited(_drainLinks());
  }

  Future<void> _drainLinks() async {
    if (_activeLink != null || !mounted || !_readyForLinks) return;
    while (_pendingLinks.isNotEmpty && mounted) {
      final uri = _pendingLinks.removeAt(0);
      _activeLink = _linkKey(uri);
      try {
        final parsed = parseGroupUrl(uri.toString())!;
        var row = await _db.groupRow(parsed.groupId);
        if (!mounted) return;
        if (row == null || row.serverUrl != parsed.serverUrl) {
          final joined =
              await Navigator.of(context).push<String>(MaterialPageRoute(
            builder: (_) => JoinGroupScreen(
                db: _db,
                initialUrl: uri.toString(),
                clientFactory: widget.clientFactory),
          ));
          if (!mounted) return;
          if (joined == null) continue;
          row = await _db.groupRow(joined);
        }
        if (row != null && mounted) await _openGroup(row);
      } finally {
        _activeLink = null;
      }
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    // Routes share this database; injected databases belong to the caller.
    if (widget.db == null) unawaited(_db.close());
    super.dispose();
  }

  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _linkSubscription =
        widget.links?.listen(_receiveLink, onError: (Object error) {
      // Invalid platform events should not prevent normal app navigation.
      debugPrint('Unable to receive app link: $error');
    });
    _start();
  }

  Future<void> _start() async {
    try {
      final initial = await widget.initialLink;
      if (initial != null) _receiveLink(initial);
    } catch (error) {
      debugPrint('Unable to read initial app link: $error');
    }
    await _migrateLegacySingleGroup();
    final last = await _db.mostRecentlyOpenedGroup();
    if (!mounted) return;
    setState(() => _checked = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _readyForLinks = true;
      if (_pendingLinks.isNotEmpty) {
        unawaited(_drainLinks());
      } else if (last != null) {
        unawaited(_openGroup(last));
      }
    });
  }

  /// Pushes [row] as a GroupScreen on top of the (always-present)
  /// GroupListScreen -- the launch fast path above, and shared by
  /// GroupListScreen's own row taps rather than duplicating this.
  Future<void> _openGroup(GroupRow row) async {
    await _db.recordGroupOpened(row.id, serverUrl: row.serverUrl);
    if (!mounted) return;
    final client = widget.clientFactory?.call(row.serverUrl) ??
        SpliitClient(baseUrl: row.serverUrl);
    final outbox = Outbox(_db, client, groupId: row.id);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GroupScreen(
            client: client, db: _db, outbox: outbox, groupId: row.id),
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
