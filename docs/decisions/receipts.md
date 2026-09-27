# spliit2go: receipts (issues #5, #123–#128)

**Status: #123 implemented** (viewing in #130, attaching in its second PR), 2026-09-27. The rest is planned in [#124](https://github.com/sharneng/spliit2go/issues/124)–[#127](https://github.com/sharneng/spliit2go/issues/127), tracked by [#5](https://github.com/sharneng/spliit2go/issues/5). The issues hold the full agreed design (Kenneth and Ezra, 2026-09-27); this records what's built and why.

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
- **Saving** waits until every photo is uploaded or removed. Leaving the form with new photos asks first. That's all phase 1 promises: a photo isn't kept if the app is closed mid-form (#124 makes it durable).
- **New expenses** carry their documents on the pending row (`documentsJson`, schema 13), and the outbox sends them with the create. The server gives them new ids, so the synced row forgets them, and they're read by their count the next time the expense is opened.
- **Edits** send the kept documents plus the new ones. Update keeps the ids it's sent, so they're stored as the expense's documents straight away. Removing one only removes it from the expense.
- **A just-uploaded photo** is stored in the viewing cache under its URL, so it shows without being downloaded back.

## The storage policy

Every receipt file on the device is recorded in the `ReceiptFiles` table with *why* it's there, which decides when it may go. The full table is in #123. Built so far:

- **Viewing cache:** receipts that were opened. Capped at about 200 MB, least recently used out first; the receipt being viewed is never evicted.
- **Cleanup by reference:** when a refresh, a delete or leaving a group removes an expense or document, the database drops its file's row in the same transaction, and `ReceiptCache.sweep` deletes files no row refers to (at startup, after a refresh, after leaving a group). Downloads are written under a temporary name and renamed, so a partial file is never taken for a receipt, and storing a file (write, rename, register) and a sweep run one at a time, so a sweep can't delete a file mid-store (#130 review).

Still to come: photos taken on this device and pending uploads (#124, never evicted or cleared while unsynced), and downloading a favorite group's receipts ahead for offline (#127), with the free-space margin those need.

## Not done yet

Offline attachments and restart durability (#124), on-device scanning (#125, #126), downloading ahead (#127).
