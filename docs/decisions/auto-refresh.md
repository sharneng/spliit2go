# The open group refreshes on its own

Written 2026-10-13 ([#301](https://github.com/sharneng/spliit2go/issues/301)). An interim answer until sync from the activity log ([#245](https://github.com/sharneng/spliit2go/issues/245)) makes refreshes incremental.

## The problem

While the phone stayed online, a group refreshed only when its screen opened, on pull to refresh, after an edit in the app, or when the connection type changed. Changes made on the web or by another member stayed hidden: an app resumed hours later still showed the group as it was, and a screen left open never updated.

## Decisions

1. **One rule** (Kenneth): while a group's screen is open and the app is in the foreground, the group refreshes once its last refresh is older than the setting's interval. The rule is checked:
   - on opening the group;
   - on coming back from the background;
   - on reconnecting, when nothing was waiting to be sent.

   It refreshes now when it's due, and otherwise waits for the rest of the interval. Nothing else refreshes on its own. Opening a group no longer always refreshes: going back to the list, to the settings or to another group and returning a moment later refreshed both groups again, which was wasted time (Kenneth).
2. **Any refresh counts:** opening, pulling, after an edit, or the timer, starting the interval again. Its time is stored with the group (`groups.refreshedAt`, schema 21), so it holds across restarts. A failed refresh, such as one offline, isn't counted, and the next try is a whole interval later or on reconnecting.
3. **The setting** (App settings, Sync, "Refresh the open group"): every 5, 10 (default), 30 or 60 minutes, or Off.
4. **Archived groups never refresh on their own**, only when pulled (Kenneth).
5. **Only the open group, only in the foreground.** The timer stops when the app goes to the background or the screen closes. It keeps running under an open expense sheet or form, since the group is still underneath. The group list doesn't refresh on its own, and nothing runs while the app is closed.
6. **Reconnecting still sends what's waiting at once.** When something was sent, the group refreshes after it, as after an edit; otherwise only by the rule.
7. **Each refresh still reads the whole list**, now 100 expenses a request (#302), so a refresh of a 200-expense group is three requests. Favorites' receipts and notes are read ahead after each refresh, as before (#127, #237).
