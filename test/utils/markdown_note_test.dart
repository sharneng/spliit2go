import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/utils/markdown_note.dart';

// Issue #311: a note opts in to markdown by its first line.
void main() {
  test('only a first line that is the marker opts in', () {
    expect(isMarkdownNote('$markdownMarker\n# Hotel'), isTrue);
    expect(isMarkdownNote('  $markdownMarker  \n# Hotel'), isTrue);
    expect(isMarkdownNote(markdownMarker), isTrue);
    expect(isMarkdownNote('# Hotel'), isFalse);
    expect(isMarkdownNote('Hotel\n$markdownMarker'), isFalse);
    expect(isMarkdownNote(''), isFalse);
  });

  test('the body drops the marker line, and only that', () {
    expect(noteBody('$markdownMarker\n# Hotel\nRoom 25'), '# Hotel\nRoom 25');
    expect(noteBody(markdownMarker), '');
    expect(noteBody('Hotel\nRoom 25'), 'Hotel\nRoom 25');
  });

  test('saved behind the marker when markdown, unless empty', () {
    expect(noteText('# Hotel', markdown: true), '$markdownMarker\n# Hotel');
    expect(noteText('# Hotel', markdown: false), '# Hotel');
    expect(noteText('', markdown: true), '');
    expect(noteBody(noteText('a\nb', markdown: true)), 'a\nb');
  });
}
