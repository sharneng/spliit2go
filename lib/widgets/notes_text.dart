import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/context_l10n.dart';
import '../utils/markdown_note.dart';

/// Opens [url] outside the app; false if nothing could.
typedef NoteLinkOpener = Future<bool> Function(Uri url);

Future<bool> _openExternally(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No browser, or the platform refused: the snack bar says so.
    return false;
  }
}

/// The schemes a note's link may open: web addresses, as in a plain note.
/// A markdown link to tel:, file: or an app's own scheme isn't opened.
const _linkSchemes = {'http', 'https'};

bool _opensLink(Uri url) => _linkSchemes.contains(url.scheme.toLowerCase());

/// A web address in a plain note: from http(s):// to the next space.
final _link = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

/// [address] without the punctuation after it that ends a sentence rather
/// than the address: "see https://x.test/a." links https://x.test/a. A
/// closing parenthesis stays when the address opened one (PR #312
/// review): https://en.wikipedia.org/wiki/Paris_(mythology).
String _withoutTrailing(String address) {
  var end = address.length;
  while (end > 0) {
    final last = address[end - 1];
    final opened = '('.allMatches(address.substring(0, end)).length;
    final closed = ')'.allMatches(address.substring(0, end)).length;
    if ('.,;:!?\'"]'.contains(last) || (last == ')' && closed > opened)) {
      end--;
    } else {
      break;
    }
  }
  return address.substring(0, end);
}

/// The images inside a link in [markdown], as their address and alt text,
/// the way [MarkdownBody.imageBuilder] gets them: its builder isn't told
/// which are (#330). Parsed as [MarkdownBody] parses, GitHub flavored.
Set<(String, String)> _linkedImages(String markdown) {
  final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false)
      .parseLines(const LineSplitter().convert(markdown));
  final found = <(String, String)>{};
  void visit(md.Node node, bool inLink) {
    if (node is! md.Element) return;
    if (node.tag == 'img' && inLink) {
      // The builder drops a #widthxheight suffix before parsing the address.
      final src = Uri.tryParse(node.attributes['src']!.split('#').first);
      if (src != null) found.add((src.toString(), node.attributes['alt'] ?? ''));
    }
    for (final child in node.children ?? const <md.Node>[]) {
      visit(child, inLink || node.tag == 'a');
    }
  }

  for (final node in nodes) {
    visit(node, false);
  }
  return found;
}

/// An expense's notes (#311): markdown when [isMarkdownNote], else as
/// written, its web addresses tappable either way. Selectable, as notes
/// were before. A markdown image is never downloaded (#325): it shows as
/// its alt text, with a button that opens a web image in the browser.
/// Inside a link, the alt text looks like the link it opens (#330).
class NotesText extends StatefulWidget {
  const NotesText(this.notes, {super.key, this.openLink = _openExternally});

  final String notes;
  final NoteLinkOpener openLink;

  @override
  State<NotesText> createState() => _NotesTextState();
}

class _NotesTextState extends State<NotesText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _open(String href) async {
    final url = Uri.tryParse(href);
    final opened = url != null && _opensLink(url) && await widget.openLink(url);
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.l10n.aboutLinkFailed(href))));
    }
  }

  /// [MarkdownBody.imageBuilder]: the image's alt text instead of the
  /// image, so showing a note contacts no one. Inside a link, a tap on the
  /// text still opens the link, and the text is styled as one: [linked].
  Widget _image(Uri uri, String? alt, {required bool linked, required TextStyle linkStyle}) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final secondary = theme.colorScheme.onSurfaceVariant;
    final label = alt?.trim() ?? '';
    final text = Text(label.isEmpty ? l10n.expenseNotesImage : label, style: linked ? linkStyle : null);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.image_outlined, size: 18, color: secondary),
        const SizedBox(width: 4),
        Flexible(child: linked ? Semantics(link: true, child: text) : text),
        if (_opensLink(uri))
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 18),
            tooltip: l10n.expenseNotesOpenImage,
            visualDensity: VisualDensity.compact,
            onPressed: () => _open(uri.toString()),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linkStyle = TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline);
    if (isMarkdownNote(widget.notes)) {
      final body = noteBody(widget.notes);
      final linked = _linkedImages(body);
      return MarkdownBody(
        data: body,
        selectable: true,
        // Line breaks as written, as in a plain note.
        softLineBreak: true,
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(a: linkStyle),
        imageBuilder: (uri, title, alt) =>
            _image(uri, alt, linked: linked.contains((uri.toString(), alt ?? '')), linkStyle: linkStyle),
        onTapLink: (text, href, title) {
          if (href != null) _open(href);
        },
      );
    }
    _disposeRecognizers();
    final spans = <InlineSpan>[];
    var at = 0;
    final notes = widget.notes;
    for (final match in _link.allMatches(notes)) {
      final href = _withoutTrailing(match[0]!);
      spans.add(TextSpan(text: notes.substring(at, match.start)));
      final recognizer = TapGestureRecognizer()..onTap = () => _open(href);
      _recognizers.add(recognizer);
      spans.add(TextSpan(text: href, style: linkStyle, recognizer: recognizer));
      at = match.start + href.length;
    }
    spans.add(TextSpan(text: notes.substring(at)));
    return SelectableText.rich(TextSpan(children: spans));
  }
}
