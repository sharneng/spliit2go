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
- **Saving** a new expense waits only for photos still being prepared or uploaded; a photo that didn't upload is saved with the expense, which syncs with it later (#124, below). Saving an edit waits until each new photo is uploaded or removed. Leaving the form with new photos asks first, and once it's discarded nothing new starts: a photo still being prepared isn't uploaded, and neither is a retry (#131 review). The form itself isn't a draft: a photo added but not saved is lost if the app is closed.
- **New expenses** carry their documents on the pending row (`documentsJson`, schema 13), and the outbox sends them with the create. Those count as references for cleanup, so a refresh while the expense is pending keeps its photos (#131 review). Once it syncs they move to `ExpenseDocuments` under the server's expense id, still with this device's ids (create gives documents new ones), until the next online open reads the real ones.
- **Edits** send the kept documents plus the new ones. Update keeps the ids it's sent, so they're stored as the expense's documents straight away. Removing one only removes it from the expense.
- **A just-uploaded photo** is stored under its URL as a *capture*, so it shows without being downloaded back, and isn't evicted.

## Offline, and kept across restarts (built, #124)

**A new expense syncs together with its receipts** (Kenneth and Ezra, #124 and #138 review). The first design synced them independently: an expense could reach the server first, and its photos followed with a read and an update. That path, and an Add receipt in the expense details that fed it, brought most of the complexity and all three bugs found in review. Kenneth wants the details to stay read-only, and edits are online-only anyway, so the path was dropped.

- **Where a photo waits:** a new expense's photo that didn't upload in the form is a row in `ReceiptAttachments` (schema 15) plus its file in the receipts directory: a *pending original*. Save stores the expense and its photos in one step, so a retried Save can't add the expense twice.
- **The outbox, per pending expense:**
  1. It uploads the expense's photos one by one.
  2. Once they're all up, it creates the expense with all of them.
  3. Their rows go, and their files become captures.

  Offline, the expense and its photos wait together.
- **States:**
  - `local`: not uploaded;
  - `uploading(url)`: signed, with its public URL recorded *before* the transfer;
  - `uploaded(url)`: in the bucket, and the expense isn't created yet.

  All of this is in the database, so an app restart at any step resumes where it was: a photo already uploaded isn't sent again when the create is retried.
- **Interrupted uploads:** the app can stop after the transfer and before `uploaded` is written. On the next flush, an `uploading` photo is checked with a `HEAD` of its public URL; spliit.app's bucket answers 200 when the object exists, 403 when it doesn't. If it's there, the photo becomes `uploaded`. If not, it's signed again (the old signature may have expired) and sent. **Exactly-once uploads aren't promised:** a retry can leave an unreferenced object in the bucket. That's accepted; losing the receipt or duplicating the expense isn't.
- **Failures (#119, #44):**
  - A connection failure counts like any failed sync attempt, and the next flush tries again.
  - Anything else while uploading, such as a server that may not store receipts, marks the expense sync failed at once, with the error. Its details offer **Retry**, **Discard**, and **Sync without receipts**. Sync without receipts asks first, since the phone has the only copy, then drops the photos and syncs the expense.

  So a receipt is only ever dropped by the user's explicit choice.
- **Edits** stay online-only: Save waits until each new photo is uploaded or removed, as before #124.
- **Identities:** a create gives documents new ids, so the local attachment id is never taken for the server's; the next read of the expense brings the real ones (#123).
- **Overlapping syncs:** the outbox runs one group's flushes one after another (#141), so two can't both create the same expense.

## The storage policy

Every receipt file on the device is recorded in the `ReceiptFiles` table with *why* it's there, which decides when it may go. The full table is in #123. Built so far:

- **Viewing cache:** receipts that were opened. Capped at about 200 MB, least recently used out first; the receipt being viewed is never evicted.
- **Cleanup by reference:** when a refresh, a delete or leaving a group removes an expense or document, the database drops its file's row in the same transaction, and `ReceiptCache.sweep` deletes files no row refers to (at startup, after a refresh, after leaving a group). Downloads are written under a temporary name and renamed, so a partial file is never taken for a receipt, and storing a file (write, rename, register) and a sweep run one at a time, so a sweep can't delete a file mid-store (#130 review).

- **Pending originals** (#124): a new expense's photos not uploaded yet. Never evicted, never removed by Clear or by a sweep; removed only when the expense is created with them, by Sync without receipts, or with a discarded expense or a group left.
- **Captures** (#124): photos from this device that are on their expense. Never evicted; removed by Clear, and with their document, expense or group. Storage's size and Clear cover stored receipts and captures, not pending originals.

Still to come: downloading a favorite group's receipts ahead for offline (#127), with the free-space margin it needs.

## Not done yet

On-device scanning (#125, #126), downloading ahead (#127).
