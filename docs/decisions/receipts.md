# spliit2go: receipts (issues #5, #123–#128)

**Status: #123 and #124 implemented** (viewing in #130, attaching in #131, offline and durable attaching in #124's PR), 2026-09-27. The rest is planned in [#125](https://github.com/sharneng/spliit2go/issues/125)–[#127](https://github.com/sharneng/spliit2go/issues/127), tracked by [#5](https://github.com/sharneng/spliit2go/issues/5). The issues hold the full agreed design (Kenneth and Ezra, 2026-09-27); this records what's built and why.

## How Spliit stores receipts

A receipt is an expense *document*: `{id, url, width, height}` (`src/lib/schemas.ts`, cc796210). The image is uploaded straight to the instance's own S3 bucket through a URL `/api/s3-upload` signs, and the expense stores only its URL.

- **Create and update treat `id` differently.** `createExpense` gives every document a fresh `randomId()`. `updateExpense` keeps the ids it's sent (`connectOrCreate`) and deletes every existing document missing from the list. That's why an edit must send back all of an expense's documents unchanged ([#128](https://github.com/sharneng/spliit2go/issues/128), fixed in #129).
- **The expense list only counts them.** `groups.expenses.list` returns `_count.documents`, not the documents; only `groups.expenses.get` returns them.
- **Removing a document only removes its reference.** Neither the web app nor iOS can delete the image from the bucket.
- **Document URLs never change** (`document-<timestamp>-<random>`), so a stored copy never goes stale.

## Viewing (built)

- **What's cached:** each expense's document count, from the list. Its documents, once read in full: opening its details online, or editing it. They're kept only while the count still matches; a refresh that finds a different count drops them. So until an expense has been opened online once, the app knows *how many* receipts it has but not what they are, and offline shows that many placeholders.
- **Stored documents are checked each time an expense is opened online** (#130 review). They show at once, but a matching count doesn't mean they're current: a receipt can be swapped on the web with the count unchanged. The sheet reads the expense once per open, replaces what's stored if it changed, and the swapped-out receipt's file is dropped.
- **The details sheet** has a Receipts section of square thumbnails; tapping one opens a full-screen viewer (swipe between receipts, pinch to zoom).
- **Offline is expected, not an error (#119).** A receipt that isn't on the device shows "Available when online" and loads by itself when the phone reconnects. A refused download (the bucket answering 403, say) is unexpected: logged, with details.
- **Storage** (App settings) shows the space stored receipts use, with Clear. They're copies, downloaded again when opened.

## Attaching (built)

- **Adding:** the form's Receipts field has Add receipt, which offers Take photo or Choose from library (image_picker; the system picker on iOS, so no photo-library permission is needed to choose one).
- **Shrinking before upload**, as spliit-ios does (`DocumentImage.swift`):
  - the camera's orientation is applied;
  - it's at most 2048 px on the long side, as JPEG, about 400 KB for a receipt;
  - **every EXIF field is dropped, including location.** The system picker warns that location is included, but the app removes it before anything leaves the phone.
- **Uploaded as soon as it's added,** like the web app: `/api/s3-upload` signs, the image goes straight to the bucket with the web app's headers, and the photo becomes a document (URL, width, height, and a new 21-character id).
- **When an upload fails (#119):** the photo stays in the form as "Not uploaded", with Retry (tap it) and Remove.
  - A connection failure says so.
  - Anything else is unexpected, with details. An empty 500 from the signing route is what an instance without storage returns, but so is any other failure there, so the message only says the server *may* not store receipts, and attaching is never disabled.
- **Saving** waits only for photos still being prepared or uploaded. A photo that didn't upload is saved with the expense and uploads later (#124, below). Leaving the form with new photos asks first, and once it's discarded nothing new starts: a photo still being prepared isn't uploaded, and neither is a retry (#131 review). The form itself isn't a draft: a photo added but not saved is lost if the app is closed.
- **New expenses** carry their documents on the pending row (`documentsJson`, schema 13), and the outbox sends them with the create. Those count as references for cleanup, so a refresh while the expense is pending keeps its photos (#131 review). Once it syncs they move to `ExpenseDocuments` under the server's expense id, still with this device's ids (create gives documents new ones), until the next online open reads the real ones.
- **Edits** send the kept documents plus the new ones. Update keeps the ids it's sent, so they're stored as the expense's documents straight away. Removing one only removes it from the expense.
- **A just-uploaded photo** is stored under its URL as a *capture*, so it shows without being downloaded back, and isn't evicted.

## Offline, and kept across restarts (built, #124)

**The expense and its receipts sync independently, and a receipt is never dropped** (Ezra, #124). A receipt is content the user provided, unlike a preference such as the default split (#119).

- **Where a photo waits:** a photo that isn't on its expense yet is a row in `ReceiptAttachments` (schema 15) plus its file in the receipts directory: a *pending original*. It gets there from:
  - the form's Save, for a photo that didn't upload;
  - the details sheet's **Add receipt**, which works offline, for any expense on this device except one whose sync failed.
- **Three identities, kept apart** (#123):
  - the *local attachment id*, stable from capture;
  - the server's document id;
  - the URL.

  An update keeps the ids it's sent, so a photo added to a synced expense goes up under its attachment id. A create gives documents new ids; the next read of the expense brings them.
- **States:**
  - `local`: not uploaded;
  - `uploading(url)`: signed, with its public URL recorded *before* the transfer;
  - `uploaded(url)`: in the bucket, not on the expense yet;
  - `failed`: an unexpected failure, waiting for Retry.

  Once it's on the expense, the row goes and the file becomes a capture. All of it is in the database, so an app restart at any step resumes where it was.
- **The outbox, for a pending expense:** it uploads the expense's photos one by one, creates the expense with the ones that made it, and keeps the rest for the now-synced expense. The expense is never held back by a photo.
- **The outbox, for a synced expense** (a photo that didn't upload in time, or one added later):
  1. It reads the expense.
  2. It adds the photos missing from its documents, keeping the others under their server ids.
  3. It updates.

  If an update's response is lost, the next read shows the photo is there, so nothing is added twice. This doesn't solve the lost-response problem for *creating* the expense itself.
- **Interrupted uploads:** the app can stop after the transfer and before `uploaded` is written. On the next flush, an `uploading` photo is checked with a `HEAD` of its public URL; spliit.app's bucket answers 200 when the object exists, 403 when it doesn't. If it's there, the photo becomes `uploaded`; if not, it's signed again (the old signature may have expired) and sent. **Exactly-once uploads aren't promised:** a retry can leave an unreferenced object in the bucket. That's accepted; losing the receipt or duplicating the expense isn't.
- **Failures (#119):**
  - A connection failure leaves the photo as it was, and the next flush (reconnecting, a refresh) tries again. It shows "Not uploaded yet: it uploads once you're back online."
  - Anything else is logged once and waits for **Retry**, with details. The message says the server may not store receipts and that the photo stays on this phone. It never says it was uploaded or discarded.
- **Remove** asks first, since the phone has the only copy.
- **Discarding** a sync-failed expense removes its photos. So does leaving the group.
- **An expense deleted on the server** can't take its waiting photos, and nothing would show them, so they're removed when the outbox finds it gone.

## The storage policy

Every receipt file on the device is recorded in the `ReceiptFiles` table with *why* it's there, which decides when it may go. The full table is in #123. Built so far:

- **Viewing cache:** receipts that were opened. Capped at about 200 MB, least recently used out first; the receipt being viewed is never evicted.
- **Cleanup by reference:** when a refresh, a delete or leaving a group removes an expense or document, the database drops its file's row in the same transaction, and `ReceiptCache.sweep` deletes files no row refers to (at startup, after a refresh, after leaving a group). Downloads are written under a temporary name and renamed, so a partial file is never taken for a receipt, and storing a file (write, rename, register) and a sweep run one at a time, so a sweep can't delete a file mid-store (#130 review).

- **Pending originals** (#124): photos not on their expense yet. Never evicted, never removed by Clear or by a sweep; removed only when they're on the expense, when the user removes one, or with a discarded expense or a group left.
- **Captures** (#124): photos from this device that are on their expense. Never evicted; removed by Clear, and with their document, expense or group. Storage's size and Clear cover stored receipts and captures, not pending originals.

Still to come: downloading a favorite group's receipts ahead for offline (#127), with the free-space margin it needs.

## Not done yet

On-device scanning (#125, #126), downloading ahead (#127).
