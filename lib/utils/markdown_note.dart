/// The first line of a note written in markdown (#311). Spliit has no field
/// for it, so the choice travels in the text. An HTML comment, so any
/// markdown renderer hides it: the Spliit website or another app, if they
/// ever render notes. Plain-text views show it as a line.
const markdownMarker = '<!-- markdown -->';

/// Whether [notes] opted in to markdown: [markdownMarker] its first line.
bool isMarkdownNote(String notes) => notes.split('\n').first.trim() == markdownMarker;

/// [notes] without the marker line, as it's edited and shown.
String noteBody(String notes) {
  if (!isMarkdownNote(notes)) return notes;
  final lineEnd = notes.indexOf('\n');
  return lineEnd < 0 ? '' : notes.substring(lineEnd + 1);
}

/// [body] as saved: behind the marker when [markdown], unless empty.
String noteText(String body, {required bool markdown}) =>
    markdown && body.isNotEmpty ? '$markdownMarker\n$body' : body;
