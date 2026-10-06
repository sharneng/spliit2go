import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/context_l10n.dart';
import '../services/build_info.dart';
import '../theme.dart';
import '../widgets/bottom_inset.dart';

/// Where About's links go (#109).
const spliitUrl = 'https://spliit.app';
const sourceCodeUrl = 'https://github.com/sharneng/spliit2go';
const supportUrl = 'https://github.com/sharneng/spliit2go/issues';

/// The privacy policy (#111), published as the rendered file in the repo.
const privacyPolicyUrl = 'https://github.com/sharneng/spliit2go/blob/main/docs/privacy.md';

/// Opens [url] outside the app; false if nothing could.
typedef LinkOpener = Future<bool> Function(Uri url);

Future<bool> _openExternally(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No browser, or the platform refused: the snack bar says so.
    return false;
  }
}

/// The app's name and version, the "unofficial client" notice Spliit's
/// author asked for (spliit-app/spliit#658), and links to Spliit, the
/// source, support, the privacy policy (#111) and the licenses page (#109).
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.openLink = _openExternally, this.loadCommit = loadBuildCommit});

  final LinkOpener openLink;

  /// The commit shown after the build number, e.g. "1.0.0 (1 · a1b2c3d)" (#176).
  final Future<BuildCommit> Function() loadCommit;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  PackageInfo? _info;
  BuildCommit? _commit;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadCommit();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _info = info);
    } catch (_) {
      // Leaves the version line out; nothing else on the screen needs it.
    }
  }

  Future<void> _loadCommit() async {
    final commit = await widget.loadCommit();
    if (!mounted) return;
    setState(() => _commit = commit);
  }

  Future<void> _open(String url) async {
    if (await widget.openLink(Uri.parse(url))) return;
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(context.l10n.aboutLinkFailed(url))));
  }

  /// Copies the version with the full commit, for bug reports (#176).
  Future<void> _copyVersion(PackageInfo info, BuildCommit commit) async {
    await Clipboard.setData(
        ClipboardData(text: 'Spliit2Go ${info.version} (${info.buildNumber} · ${commit.full})'));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(context.l10n.aboutVersionCopied)));
  }

  Widget _logo(double size) =>
      Image.asset('assets/spliit2go-logo.png', width: size, height: size, excludeFromSemantics: true);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = _info;
    final commit = _commit;
    String? version;
    if (info != null) {
      // The build number alone until the commit has loaded.
      final shown = commit == null ? null : (commit.known ? commit.short : l10n.aboutCommitUnknown);
      version = l10n.aboutVersion(
          info.version, shown == null ? info.buildNumber : '${info.buildNumber} · $shown');
    }
    Widget link(IconData icon, String title, String subtitle, String url) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.open_in_new, size: 20),
          onTap: () => _open(url),
        );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        padding: withBottomInset(context, const EdgeInsets.symmetric(vertical: 24)),
        children: [
          Center(child: _logo(72)),
          const SizedBox(height: 12),
          Text('Spliit2Go',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700, color: spliitWordmarkGreen)),
          if (version != null) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(version,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
                if (commit != null && commit.known)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: l10n.aboutCopyVersion,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _copyVersion(info!, commit),
                  ),
              ],
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Text(l10n.aboutUnofficial,
                textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ),
          const Divider(height: 32),
          link(Icons.public, 'Spliit', l10n.aboutSpliitSubtitle, spliitUrl),
          link(Icons.code, l10n.aboutSourceCode, 'github.com/sharneng/spliit2go', sourceCodeUrl),
          link(Icons.help_outline, l10n.aboutSupport, l10n.aboutSupportSubtitle, supportUrl),
          link(Icons.privacy_tip_outlined, l10n.aboutPrivacyPolicy, l10n.aboutPrivacyPolicySubtitle,
              privacyPolicyUrl),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(l10n.aboutLicenses),
            subtitle: Text(l10n.aboutLicensesSubtitle),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Spliit2Go',
              applicationVersion: version,
              applicationIcon: Padding(padding: const EdgeInsets.all(8), child: _logo(48)),
            ),
          ),
        ],
      ),
    );
  }
}
