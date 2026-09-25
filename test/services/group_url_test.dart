import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/group_url.dart';

void main() {
  group('parseGroupUrl', () {
    test('splits a plain spliit.app URL', () {
      final result = parseGroupUrl('https://spliit.app/groups/RrYePXN2GBpSMW1EPjpjH');
      expect(result?.serverUrl, 'https://spliit.app');
      expect(result?.groupId, 'RrYePXN2GBpSMW1EPjpjH');
    });

    test('ignores anything after the group id, e.g. /expenses', () {
      final result = parseGroupUrl('https://spliit.app/groups/abc123/expenses');
      expect(result?.serverUrl, 'https://spliit.app');
      expect(result?.groupId, 'abc123');
    });

    test('keeps a self-hosted sub-path as part of the server URL', () {
      final result = parseGroupUrl('https://example.com/spliit/groups/abc123');
      expect(result?.serverUrl, 'https://example.com/spliit');
      expect(result?.groupId, 'abc123');
    });

    test('keeps a non-default port', () {
      final result = parseGroupUrl('http://192.168.1.5:3000/groups/abc123');
      expect(result?.serverUrl, 'http://192.168.1.5:3000');
      expect(result?.groupId, 'abc123');
    });

    test('accepts a missing scheme, defaulting to https', () {
      final result = parseGroupUrl('spliit.app/groups/abc123');
      expect(result?.serverUrl, 'https://spliit.app');
      expect(result?.groupId, 'abc123');
    });

    test('trims surrounding whitespace', () {
      final result = parseGroupUrl('  https://spliit.app/groups/abc123  ');
      expect(result?.serverUrl, 'https://spliit.app');
      expect(result?.groupId, 'abc123');
    });

    // A literal reproduction of the URL from
    // github.com/sharneng/spliit2go/issues/14's followup -- Kenneth
    // suspected the group-id parsing itself was the root cause of both
    // the wrong "$" currency and the type-cast crash on newly-joined
    // groups. It isn't: this parses exactly as expected, same as the
    // more general /expenses-suffix case above -- the group id comes
    // out byte-for-byte what's in the URL, no truncation, no case
    // folding, nothing dropped or mangled.
    test("parses Kenneth's real Alaska group link, exactly", () {
      final result = parseGroupUrl('https://spliit.app/groups/vXuLheivMWCzBkvqCDELI/expenses');
      expect(result?.serverUrl, 'https://spliit.app');
      expect(result?.groupId, 'vXuLheivMWCzBkvqCDELI');
    });

    test('returns null for a bare group id with no /groups/ segment', () {
      expect(parseGroupUrl('RrYePXN2GBpSMW1EPjpjH'), isNull);
    });

    test('returns null for a server URL with nothing after /groups/', () {
      expect(parseGroupUrl('https://spliit.app/groups/'), isNull);
      expect(parseGroupUrl('https://spliit.app/groups'), isNull);
    });

    test('returns null for empty or blank input', () {
      expect(parseGroupUrl(''), isNull);
      expect(parseGroupUrl('   '), isNull);
    });

    test('returns null for garbage input', () {
      expect(parseGroupUrl('not a url at all'), isNull);
    });
  });

  // Issue #115: a server address typed for a new group.
  group('normalizeServerUrl', () {
    test('adds https and drops a trailing slash', () {
      expect(normalizeServerUrl('spliit.example.com'), 'https://spliit.example.com');
      expect(normalizeServerUrl(' https://spliit.app/ '), 'https://spliit.app');
    });

    test('keeps a sub-path, port and http', () {
      expect(normalizeServerUrl('example.com/spliit/'), 'https://example.com/spliit');
      expect(normalizeServerUrl('http://192.168.1.5:3000'), 'http://192.168.1.5:3000');
      expect(normalizeServerUrl('http://localhost:3000'), 'http://localhost:3000');
    });

    test('drops a query and fragment', () {
      expect(normalizeServerUrl('https://spliit.app/?x=1#y'), 'https://spliit.app');
    });

    test('rejects something that isn\'t an address', () {
      expect(normalizeServerUrl(''), isNull);
      expect(normalizeServerUrl('   '), isNull);
      expect(normalizeServerUrl('not a server'), isNull);
    });
  });

  test('serverDisplayName drops https only', () {
    expect(serverDisplayName('https://spliit.app'), 'spliit.app');
    expect(serverDisplayName('http://192.168.1.5:3000'), 'http://192.168.1.5:3000');
  });
}
