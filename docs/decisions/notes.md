# Notes: links and markdown

Written 2026-10-13 ([#311](https://github.com/sharneng/spliit2go/issues/311)), with Kenneth.

## The problem

Notes were plain, selectable text. A pasted booking or receipt link couldn't be tapped, and someone who writes markdown saw its symbols instead of the formatting.

## Decisions

1. **Links in every note are tappable** in the expense details sheet, and open in the browser. An address runs from `http://` or `https://` to the next space; punctuation that ends a sentence after it isn't part of it, except a closing parenthesis the address opened, as in `https://en.wikipedia.org/wiki/Paris_(mythology)` (PR #312 review). A link that can't be opened says so in a snack bar.
2. **Markdown only when the note opts in.** Guessing whether a note is markdown is unreliable: a line starting with `-` or `1.` may or may not be a list. Most people don't write markdown, and their notes must look exactly as typed, so plain notes are never rendered.
3. **The choice lives in the note:** its first line is `<!-- markdown -->`. Spliit has no field for it, so this is the only way it travels with the expense to other devices. It's an HTML comment, which markdown renderers hide, so if the Spliit website or another app ever renders notes, the marker disappears there too. In plain-text views (spliit.app and spliit-ios today) it shows as a line of text.
4. **Nobody types the marker.** The form's Notes card has a **Markdown** switch that adds or removes it; the field never shows it. When it's on, an **Edit / Preview** control shows the note as it will look. An empty note is saved empty, without the marker. The marker counts toward Spliit's 5,000-character limit. Typing stops there, but turning the switch on for a note already near it can pass it: saving is then refused with how many characters too many, in Edit even from Preview, and nothing is cut (PR #312 review).
5. **Line breaks are kept as written**, as in a plain note (`softLineBreak`), and so are a markdown note's leading spaces: four make a code block (PR #312 review). Plain notes are still trimmed. Other rules are standard markdown, so a line right after a list item continues that item.
6. **Rendering:** `flutter_markdown_plus`, the maintained continuation of Flutter's discontinued `flutter_markdown`, styled from the theme, selectable as plain notes are.
