import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../l10n/context_l10n.dart';
import '../models/expense.dart';
import '../services/error_reporting.dart';
import '../services/receipt_cache.dart';
import '../services/receipt_photo.dart';
import 'error_message.dart';
import 'receipts.dart';

enum ReceiptUpload { uploading, uploaded, failed }

/// A photo added in the open form (#123). It's uploaded as soon as it's
/// added, as the web app and spliit-ios do, so it's a document (a URL) by
/// the time the expense is saved.
class ReceiptAttachment {
  ReceiptAttachment(this.photo);

  final PreparedReceipt photo;
  ReceiptUpload state = ReceiptUpload.uploading;
  ExpenseDocument? document;

  /// Why the last upload failed.
  ReportedError? error;
}

/// The receipts in an open expense form (#123): the expense's existing
/// documents, and photos added here.
///
/// Phase 1's promise, as agreed on #123: a photo that isn't uploaded stays
/// in this form, "Not uploaded", with Retry and Remove; the form can't be
/// saved until each is uploaded or removed, and leaving asks first. It
/// isn't kept if the app is closed mid-form; that's #124.
class ReceiptAttachmentsController extends ChangeNotifier {
  ReceiptAttachmentsController({
    required this.client,
    required this.cache,
    required this.groupId,
    List<ExpenseDocument> existing = const [],
    Future<PreparedReceipt> Function(Uint8List)? prepare,
  })  : kept = List.of(existing),
        _prepare = prepare ?? prepareReceiptPhoto;

  final SpliitClient client;
  final ReceiptCache cache;
  final String groupId;
  final Future<PreparedReceipt> Function(Uint8List) _prepare;

  /// The expense's documents still attached. Removing one only removes it
  /// from the expense: the image stays in the bucket (#123).
  final List<ExpenseDocument> kept;
  final List<ReceiptAttachment> added = [];
  bool _disposed = false;

  /// Photos being prepared (shrunk) before they're added.
  int preparing = 0;

  bool get busy => preparing > 0 || added.any((a) => a.state == ReceiptUpload.uploading);
  bool get hasFailed => added.any((a) => a.state == ReceiptUpload.failed);

  /// Photos added in this form: what leaving it would lose.
  bool get hasNew => added.isNotEmpty || preparing > 0;

  /// What the expense saves with: the kept documents, then the uploads.
  List<ExpenseDocument> get documents => [
        ...kept,
        for (final a in added)
          if (a.document case final d?) d,
      ];

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Prepares [original] and uploads it. Throws if the photo can't be
  /// read (it's then not added); upload failures stay on the attachment.
  Future<void> add(Uint8List original) async {
    preparing++;
    _changed();
    final PreparedReceipt photo;
    try {
      photo = await _prepare(original);
    } finally {
      preparing--;
      _changed();
    }
    // The form was discarded while the photo was being prepared: nothing
    // may start after that (#131 review).
    if (_disposed) return;
    final attachment = ReceiptAttachment(photo);
    added.add(attachment);
    await _upload(attachment);
  }

  Future<void> retry(ReceiptAttachment a) => _upload(a);

  void remove(ReceiptAttachment a) {
    added.remove(a);
    _changed();
  }

  void removeExisting(ExpenseDocument d) {
    kept.remove(d);
    _changed();
  }

  Future<void> _upload(ReceiptAttachment a) async {
    // Never start an upload for a discarded form. One already sent may
    // leave an orphan in the bucket, which is accepted (#124).
    if (_disposed) return;
    a
      ..state = ReceiptUpload.uploading
      ..error = null;
    _changed();
    try {
      final url = await client.uploadReceipt(a.photo.bytes);
      // Shown from this device, not downloaded back. Best effort.
      try {
        await cache.store(url, groupId: groupId, bytes: a.photo.bytes);
      } catch (e, st) {
        ErrorReporter.instance.report(e, st, operation: 'Storing an uploaded receipt');
      }
      a
        ..document = ExpenseDocument(
            id: ExpenseDocument.newId(), url: url, width: a.photo.width, height: a.photo.height)
        ..state = ReceiptUpload.uploaded;
    } catch (e, st) {
      a
        ..error = ErrorReporter.instance.report(e, st, operation: 'Uploading a receipt')
        ..state = ReceiptUpload.failed;
    }
    _changed();
  }
}

/// The form's Receipts field (#123): thumbnails with Remove, Retry on the
/// ones that didn't upload, and Add receipt.
class ReceiptAttachmentsField extends StatelessWidget {
  const ReceiptAttachmentsField({super.key, required this.controller, required this.onAdd});

  final ReceiptAttachmentsController controller;

  /// Asks where the photo comes from and adds it.
  final void Function(ReceiptSource source) onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final failure = controller.added
            .where((a) => a.state == ReceiptUpload.failed)
            .map((a) => a.error)
            .firstOrNull;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.expenseReceiptsHeading, style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final d in controller.kept)
                    _RemovableTile(
                      key: ValueKey(d.url),
                      onRemove: () => controller.removeExisting(d),
                      child: ReceiptImage(cache: controller.cache, groupId: controller.groupId, url: d.url),
                    ),
                  for (final a in controller.added)
                    _RemovableTile(
                      key: ObjectKey(a),
                      onRemove: () => controller.remove(a),
                      onTap: a.state == ReceiptUpload.failed ? () => controller.retry(a) : null,
                      child: _AddedPhoto(a),
                    ),
                  for (var i = 0; i < controller.preparing; i++)
                    const _RemovableTile(child: _Spinner()),
                  _AddTile(onAdd: onAdd),
                ],
              ),
              if (failure != null) ...[
                const SizedBox(height: 4),
                ErrorMessage(
                  failure.kind == ErrorKind.connection
                      ? l10n.expenseReceiptNotUploadedConnection
                      : l10n.expenseReceiptNotUploadedServer,
                  diagnostics: failure.diagnostics,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AddedPhoto extends StatelessWidget {
  const _AddedPhoto(this.a);
  final ReceiptAttachment a;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(a.photo.bytes,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
        if (a.state != ReceiptUpload.uploaded)
          ColoredBox(
            color: Colors.black45,
            child: Center(
              child: a.state == ReceiptUpload.uploading
                  ? Semantics(label: l10n.expenseReceiptUploading, child: const _Spinner(light: true))
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.refresh, color: Colors.white),
                        Text(l10n.expenseReceiptNotUploaded,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white)),
                      ],
                    ),
            ),
          ),
      ],
    );
  }
}

class _RemovableTile extends StatelessWidget {
  const _RemovableTile({super.key, required this.child, this.onRemove, this.onTap});

  static const double size = 88;
  final Widget child;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Material(
                color: theme.colorScheme.surfaceContainerHighest,
                child: InkWell(onTap: onTap, child: child),
              ),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: 2,
              right: 2,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onRemove,
                  child: Tooltip(
                    message: context.l10n.expenseReceiptRemove,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 16, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onAdd});
  final void Function(ReceiptSource source) onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SizedBox.square(
      dimension: _RemovableTile.size,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.all(4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () async {
          final source = await showModalBottomSheet<ReceiptSource>(
            context: context,
            showDragHandle: true,
            builder: (sheetContext) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: Text(l10n.expenseReceiptTakePhoto),
                    onTap: () => Navigator.pop(sheetContext, ReceiptSource.camera),
                  ),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: Text(l10n.expenseReceiptChoosePhoto),
                    onTap: () => Navigator.pop(sheetContext, ReceiptSource.library),
                  ),
                ],
              ),
            ),
          );
          if (source != null) onAdd(source);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_a_photo_outlined, color: theme.colorScheme.primary),
            const SizedBox(height: 4),
            Text(l10n.expenseReceiptAdd,
                textAlign: TextAlign.center, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({this.light = false});
  final bool light;

  @override
  Widget build(BuildContext context) => Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: light ? Colors.white : null),
        ),
      );
}
