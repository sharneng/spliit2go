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
}
