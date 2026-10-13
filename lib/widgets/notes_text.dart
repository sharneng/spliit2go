import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
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

/// An expense's notes (#311): markdown when [isMarkdownNote], else as
/// written, its web addresses tappable either way. Selectable, as notes
/// were before.
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
    final opened = url != null && url.hasScheme && await widget.openLink(url);
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.l10n.aboutLinkFailed(href))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linkStyle = TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline);
    if (isMarkdownNote(widget.notes)) {
      return MarkdownBody(
        data: noteBody(widget.notes),
        selectable: true,
        // Line breaks as written, as in a plain note.
        softLineBreak: true,
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(a: linkStyle),
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
