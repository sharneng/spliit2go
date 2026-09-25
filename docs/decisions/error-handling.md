# spliit2go: how errors are handled and shown (issues #118, #119)

**Status: implemented** in [#119](https://github.com/sharneng/spliit2go/pull/119) (closing [#118](https://github.com/sharneng/spliit2go/issues/118)), 2026-09-25.

Joining a group on Android failed with "Couldn't join: type 'Null' is not a subtype of type 'Map<String, dynamic>'" and nothing in the debug log. Kenneth asked whether the app needs a way to see the full error on the phone. The first version showed and logged details for every error; Kenneth and Ezra pointed out that a known user error isn't a bug, and that details and logs for it are noise. So the app has one policy, in one place (`lib/services/error_reporting.dart`), and screens only supply what they were doing and their own wording.

## The three kinds

| Kind | Examples | User sees | Logged | Details |
|---|---|---|---|---|
| **User** | a link to a group that doesn't exist (`GroupNotFoundException`), invalid input | the screen's specific guidance | no | no |
| **Connection** | offline (`SocketException`, `http.ClientException`), a timeout, the server briefly unavailable (HTTP 502/503/504) | "Couldn't reach the server. Check your connection and try again." | no | no |
| **Unexpected** | everything else: a malformed response, a failed type cast, a database failure, a 4xx or 500 from the server, anything unknown | the screen's short message ("Couldn't join the group.") | once, with its stack | **Tap for details**: the operation, the error and the stack trace, copyable |

- **Only specific, known cases are expected.** Catching an exception doesn't make it expected, and a generic `Exception` or an HTTP 4xx isn't assumed to be the user's fault (Ezra's point). `classifyError` lists the known cases; anything else is unexpected.
- **Raw exception text never goes in the message.** It's in the details, where it's useful, not in front of the user.
- **"Not found" means exactly Spliit's contract.** `groups.get` answers an unknown id with an explicit `{group: null}`; only that is `GroupNotFoundException`. A missing or wrong-typed `group` is a `SpliitResponseFormatException`: unexpected, because it's the service's problem, not the link's.

## Where it applies

- **Screens with an inline error:** Join, group settings and create, the expense form's save (including a new expense's local database write, which used to leave the form stuck on "Saving…"), the expense details sheet's load, Edit and Delete, Activity, and the group screen. Delete keeps its double-check (a failed delete is verified with a fetch; "not found" then means it worked); its failures are reported instead of dropped.
- **Snack bars:** saving an app setting or a group-list change; Details appears only for an unexpected error.
- **Best-effort work that falls back silently** (category names, a refresh after settling up, the outbox's sync, app links, connectivity watching): reported, so an unexpected failure is logged even though the user sees nothing. A missing platform plugin (widget tests) is expected there.
- **Errors nothing caught:** `installErrorHandlers` routes Flutter framework errors (`FlutterError.onError`) and uncaught async errors (`PlatformDispatcher.onError`) to the same reporter. They're shown after the frame as a snack bar, "Something went wrong." with Details (`UncaughtErrorPresenter`), never from inside a failing build. An error a screen already reported and rethrew isn't reported again.

## Presentation

`ErrorMessage` shows a message, with "Tap for details" only when there are diagnostics; the sheet shows the message, operation, error and stack, selectable, with Copy. Without details the message is selectable text, so one that carries a link (a created group that couldn't be loaded, #116) can still be copied. See SETUP.md, "Diagnosing errors on a device".
