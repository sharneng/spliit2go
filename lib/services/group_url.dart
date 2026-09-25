/// Splits a pasted Spliit group URL into the server it's hosted on and
/// the group's id -- the two pieces [JoinGroupScreen] used to make the
/// user type into separate fields before this. Mirrors both the iOS
/// app and the webapp: paste the full URL from the browser/share sheet,
/// the app extracts the rest -- see
/// github.com/sharneng/spliit2go/issues/13.
///
/// A Spliit group URL always has the shape
/// `<server>/groups/<groupId>[/<anything>]`, e.g.
/// `https://spliit.app/groups/RrYePXN2GBpSMW1EPjpjH` or
/// `https://spliit.app/groups/RrYePXN2GBpSMW1EPjpjH/expenses`. A
/// self-hosted instance can live under a sub-path too (e.g.
/// `https://example.com/spliit/groups/abc`) -- everything up to
/// `/groups/` is kept as the server URL, not just the origin.
///
/// A scheme is optional on input (`spliit.app/groups/abc` is accepted,
/// treated as `https://`) since that's a plausible paste from a share
/// sheet that dropped it, but the returned `serverUrl` always has one.
///
/// Returns null if [input] doesn't look like a group URL at all --
/// no bare group id fallback, since a bare id alone can't tell us
/// which server it's on.
///
/// The link may sit inside other text, as shared messages often put it:
/// "Road trip https://spliit.app/groups/abc" (a subject in front, as some
/// Android share targets add) or "…/groups/abc." at the end of a sentence
/// (issue #118). The first `http(s)://` link is taken if there is one,
/// and the id stops at the first character a Spliit id can't contain
/// (they're nanoids: letters, digits, `_` and `-`), so trailing
/// punctuation isn't sent to the server as part of the id.
({String serverUrl, String groupId})? parseGroupUrl(String input) {
  var trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  final link = RegExp(r'https?://\S+', caseSensitive: false).firstMatch(trimmed);
  if (link != null) {
    trimmed = link.group(0)!;
  } else if (trimmed.contains(RegExp(r'\s'))) {
    // No scheme: take the word that holds the group path.
    final word = trimmed.split(RegExp(r'\s+')).where((w) => w.contains('/groups/'));
    if (word.isEmpty) return null;
    trimmed = word.first;
  }

  var uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) {
    uri = Uri.tryParse('https://$trimmed');
  }
  if (uri == null || uri.host.isEmpty) return null;

  final segments = uri.pathSegments;
  final groupsIndex = segments.indexOf('groups');
  if (groupsIndex == -1 || groupsIndex + 1 >= segments.length) return null;

  final groupId =
      RegExp(r'^[A-Za-z0-9_-]+').firstMatch(segments[groupsIndex + 1])?.group(0) ?? '';
  if (groupId.isEmpty) return null;

  final serverUrl = Uri(
    scheme: uri.scheme.isEmpty ? 'https' : uri.scheme.toLowerCase(),
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: segments.sublist(0, groupsIndex),
  ).toString();

  return (serverUrl: serverUrl, groupId: groupId);
}

/// A Spliit server address as typed for a new group (issue #115), e.g.
/// `spliit.example.com` or `https://example.com/spliit/`, as the server
/// URL groups store: scheme added (`https://`) if missing, no trailing
/// slash, query or fragment. Null if it has no host.
String? normalizeServerUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  var uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) uri = Uri.tryParse('https://$trimmed');
  if (uri == null || uri.host.isEmpty || !uri.host.contains('.') && uri.host != 'localhost') {
    return null;
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: uri.pathSegments.where((s) => s.isNotEmpty),
  ).toString();
}

/// How a server URL reads in a list: without `https://`.
String serverDisplayName(String serverUrl) =>
    serverUrl.replaceFirst(RegExp(r'^https://'), '');

/// The link that opens [groupId] on [serverUrl]: what "Share group" sends
/// (issue #3), the same `<server>/groups/<id>` link spliit-ios shares and
/// [parseGroupUrl] reads back.
Uri groupShareLink(String serverUrl, String groupId) {
  final server = Uri.parse(serverUrl);
  return server.replace(
    pathSegments: [...server.pathSegments.where((s) => s.isNotEmpty), 'groups', groupId],
  );
}

