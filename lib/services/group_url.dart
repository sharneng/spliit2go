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
({String serverUrl, String groupId})? parseGroupUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  var uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) {
    uri = Uri.tryParse('https://$trimmed');
  }
  if (uri == null || uri.host.isEmpty) return null;

  final segments = uri.pathSegments;
  final groupsIndex = segments.indexOf('groups');
  if (groupsIndex == -1 || groupsIndex + 1 >= segments.length) return null;

  final groupId = segments[groupsIndex + 1];
  if (groupId.isEmpty) return null;

  final serverUrl = Uri(
    scheme: uri.scheme.isEmpty ? 'https' : uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: segments.sublist(0, groupsIndex),
  ).toString();

  return (serverUrl: serverUrl, groupId: groupId);
}
