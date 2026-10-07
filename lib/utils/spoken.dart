/// [sentences] as one screen-reader label, each ended with [end] (the
/// locale's full stop, `spokenSentenceEnd`) unless it already ends in
/// punctuation ("syncing…"), so the reader pauses between them (#207).
/// Spaced after a Latin full stop; a Chinese 。 needs none.
String spokenSentences(Iterable<String> sentences, String end) => sentences
    .where((sentence) => sentence.isNotEmpty)
    .map((sentence) => RegExp(r'[.。…!?！？]$').hasMatch(sentence) ? sentence : '$sentence$end')
    .join(end == '.' ? ' ' : '');
