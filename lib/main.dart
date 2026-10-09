import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/spliit_client.dart';
import 'db/app_database.dart';
import 'db/connection.dart';
import 'legal/upstream_licenses.dart';
import 'l10n/app_localizations.dart';
import 'screens/group_list_screen.dart';
import 'screens/group_screen.dart';
import 'screens/join_group_screen.dart';
import 'services/exchange_rates.dart';
import 'services/group_url.dart';
import 'services/settings_service.dart';
import 'services/app_settings.dart';
import 'sync/outbox.dart';
import 'theme.dart';
import 'services/error_reporting.dart';
import 'services/receipt_cache.dart';
import 'services/receipt_scanner.dart';
import 'widgets/error_message.dart';
import 'app_name.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Errors nothing caught, framework and async alike, go through the same
  // reporter the screens use (issue #119 review).
  installErrorHandlers(ErrorReporter.instance);
  // Spliit's and spliit-ios's notices on the licenses page (#109).
  registerUpstreamLicenses();
  final links = AppLinks();
  final settings = await AppSettings.load(SettingsService());
  // The Document Scanner downloads on first use: get it as soon as the
  // phone is online, so the first scan has it (#125). The same, once, for
  // the phone's language's receipt text model (#153).
  ReceiptScannerWarmup(
    const PlatformReceiptScanner(),
    phoneScript: ReceiptScript.forLanguage(WidgetsBinding.instance.platformDispatcher.locale.languageCode),
  ).start();
  runApp(Spliit2GoApp(
      settings: settings,
      home: AppRoot(
        links: links.uriLinkStream,
        initialLink: links.getInitialLink(),
      )));
}

/// The app's navigator, so the uncaught-error snack bar can open its
/// details sheet from above the Navigator (see UncaughtErrorPresenter).
final appNavigatorKey = GlobalKey<NavigatorState>();

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
          title: appName,
          navigatorKey: appNavigatorKey,
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
          highContrastTheme: spliit2goLightHighContrastTheme,
          highContrastDarkTheme: spliit2goDarkHighContrastTheme,
          themeMode: settings.themeMode,
          home: home ?? const AppRoot(),
          // Issue #24: modern Android (edge-to-edge is mandatory starting
          // with API 35) draws the app behind the status bar *and* the
          // bottom gesture/nav bar, and the system nav bar is always
          // transparent (Window.setNavigationBarColor is a no-op there), so
          // it's the app's job to paint behind it.
          //
          // #24 first inset every route above that bar with an app-wide
          // SafeArea(top: false), and painted the strip below it in the
          // theme's background. #197 keeps it for the sides only (a
          // landscape phone's cutout): content and sheets now run to the
          // screen's bottom edge (the group screen's floating bar has lists
          // scroll behind it), and a sheet's or dialog's barrier dims the
          // whole screen (#190). Each screen and sheet keeps its own last
          // row above the bar instead (withBottomInset, or a SafeArea of
          // its own). The backdrop below is kept for any route that leaves
          // the strip unpainted.
          //
          // Theme.of(context) here resolves to whichever of
          // theme/darkTheme MaterialApp picked for the current system
          // brightness, so both the backdrop and the overlay style stay
          // correct across light and dark mode (issue #25) without needing
          // their own brightness plumbing.
          builder: (context, child) => UncaughtErrorPresenter(
            reporter: ErrorReporter.instance,
            navigatorKey: appNavigatorKey,
            child: spliit2goAppBuilder(context, child),
          ),
        ),
      ),
    );
  }
}

/// The `MaterialApp.builder` above, pulled out as a top-level function
/// so its behavior (the Container backdrop + AnnotatedRegion, both
/// explained in the comment above) is unit-testable directly with a
/// throwaway `home`, without booting the real app's `_Root` and its
/// live AppDatabase/sqlite connection.
Widget spliit2goAppBuilder(BuildContext context, Widget? child) {
  final theme = Theme.of(context);
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: spliit2goSystemUiOverlayStyle(theme),
    child: Container(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(top: false, bottom: false, child: child!),
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
        widget.links?.listen(_receiveLink, onError: (Object error, StackTrace stack) {
      // Invalid platform events should not prevent normal app navigation,
      // but aren't expected either: logged (#119 review).
      ErrorReporter.instance.report(error, stack, operation: 'Receiving an app link');
    });
    // Receipt files whose expense went away while the app was closed (#123).
    unawaited(ReceiptCache.of(_db).sweep());
    // Exchange rates fetched over 180 days ago (#252).
    unawaited(ExchangeRates.of(_db).cleanUp());
    // The receipt storage limit chosen in App settings (#127).
    unawaited(_applyReceiptLimit());
    _start();
  }

  Future<void> _applyReceiptLimit() async {
    try {
      ReceiptCache.of(_db).limit = await SettingsService().receiptStorageLimitMb() * 1024 * 1024;
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Reading the receipt storage limit');
    }
  }

  Future<void> _start() async {
    try {
      final initial = await widget.initialLink;
      if (initial != null) _receiveLink(initial);
    } catch (error, stack) {
      ErrorReporter.instance.report(error, stack, operation: 'Reading the initial app link');
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
