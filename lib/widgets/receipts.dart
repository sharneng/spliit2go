import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/context_l10n.dart';
import '../models/expense.dart';
import '../services/error_reporting.dart';
import '../services/receipt_cache.dart';
import 'error_message.dart';

/// An expense's receipts (#123): a row of thumbnails that open a
/// full-screen viewer.
///
/// [documents] is null while they aren't known yet: the expense list only
/// says how many there are ([count]), so until the expense has been read
/// in full, each shows as a placeholder, loading while [online] (the
/// details sheet is reading them) and "available when online" otherwise.
/// A receipt that isn't on this device and can't be downloaded offline is
/// expected, not an error, and loads by itself once back online.
class ReceiptsSection extends StatefulWidget {
  const ReceiptsSection({
    super.key,
    required this.cache,
    required this.groupId,
    required this.count,
    required this.documents,
    required this.online,
    this.loadDiagnostics,
  });

  final ReceiptCache cache;
  final String groupId;
  final int count;
  final List<ExpenseDocument>? documents;

  /// Null while the platform hasn't said.
  final bool? online;

  /// Set when reading the documents failed unexpectedly (#119).
  final String? loadDiagnostics;

  @override
  State<ReceiptsSection> createState() => _ReceiptsSectionState();
}

class _ReceiptsSectionState extends State<ReceiptsSection> {
  /// Receipts that couldn't be shown, by URL: offline (null) or an
  /// unexpected failure (its diagnostics).
  final _unavailable = <String, String?>{};

  void _onTileState(String url, _TileState state, String? diagnostics) {
    final changed = switch (state) {
      _TileState.offline => !_unavailable.containsKey(url) || _unavailable[url] != null,
      _TileState.failed => _unavailable[url] != diagnostics,
      _ => _unavailable.containsKey(url),
    };
    if (!changed) return;
    // Reported from a tile's own build-time load, so wait for the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        switch (state) {
          case _TileState.offline:
            _unavailable[url] = null;
          case _TileState.failed:
            _unavailable[url] = diagnostics;
          case _TileState.loading || _TileState.loaded:
            _unavailable.remove(url);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final documents = widget.documents;
    final unknownOffline = documents == null && widget.online == false;
    final failure = _unavailable.values.whereType<String>().firstOrNull ?? widget.loadDiagnostics;
    final offline = unknownOffline || _unavailable.containsValue(null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.expenseReceiptsHeading, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (documents == null)
              for (var i = 0; i < widget.count; i++)
                _Tile(
                  key: ValueKey('receipt-placeholder-$i'),
                  child: widget.online == false || widget.loadDiagnostics != null
                      ? const _TileIcon(Icons.cloud_off_outlined)
                      : const _TileSpinner(),
                )
            else
              for (final (i, d) in documents.indexed)
                _ReceiptThumbnail(
                  key: ValueKey(d.url),
                  cache: widget.cache,
                  groupId: widget.groupId,
                  document: d,
                  online: widget.online,
                  onState: (state, diagnostics) => _onTileState(d.url, state, diagnostics),
                  onOpen: () => showReceiptViewer(context,
                      cache: widget.cache,
                      groupId: widget.groupId,
                      documents: documents,
                      initialIndex: i),
                ),
          ],
        ),
        if (failure != null) ...[
          const SizedBox(height: 4),
          ErrorMessage(l10n.receiptLoadFailed, diagnostics: failure),
        ] else if (offline) ...[
          const SizedBox(height: 4),
          Text(l10n.receiptAvailableWhenOnline, style: muted),
        ],
      ],
    );
  }
}

enum _TileState { loading, loaded, offline, failed }

/// One receipt, shown square and cropped, from this device when it's
/// stored there, downloaded when it isn't (#123).
class _ReceiptThumbnail extends StatefulWidget {
  const _ReceiptThumbnail({
    super.key,
    required this.cache,
    required this.groupId,
    required this.document,
    required this.online,
    required this.onOpen,
    this.onState,
  });

  final ReceiptCache cache;
  final String groupId;
  final ExpenseDocument document;
  final bool? online;
  final VoidCallback onOpen;
  final void Function(_TileState state, String? diagnostics)? onState;

  @override
  State<_ReceiptThumbnail> createState() => _ReceiptThumbnailViewState();
}

class _ReceiptThumbnailViewState extends State<_ReceiptThumbnail> {
  final _loader = _ReceiptLoader();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ReceiptThumbnail old) {
    super.didUpdateWidget(old);
    // Back online: retry what couldn't load offline.
    if (old.online != true && widget.online == true && _loader.state == _TileState.offline) {
      _load();
    }
  }

  Future<void> _load() async {
    await _loader.load(widget.cache, widget.document.url, widget.groupId, onChange: () {
      if (mounted) setState(() {});
      widget.onState?.call(_loader.state, _loader.diagnostics);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final file = _loader.file;
    return Semantics(
      button: true,
      label: l10n.receiptOpen,
      child: _Tile(
        onTap: switch (_loader.state) {
          _TileState.loaded => widget.onOpen,
          _TileState.failed || _TileState.offline => _load,
          _TileState.loading => null,
        },
        child: switch (_loader.state) {
          _TileState.loaded => Image.file(file!,
              fit: BoxFit.cover,
              width: _Tile.size,
              height: _Tile.size,
              // A stored file that isn't a readable image (the server sent
              // something else): shown as broken rather than as nothing.
              errorBuilder: (_, __, ___) => const _TileIcon(Icons.broken_image_outlined)),
          _TileState.loading => const _TileSpinner(),
          _TileState.offline => const _TileIcon(Icons.cloud_off_outlined),
          _TileState.failed => const _TileIcon(Icons.broken_image_outlined),
        },
      ),
    );
  }
}

/// A stored receipt's image, filling its box (the expense form's tiles):
/// from this device, or downloaded, with the same offline and failure
/// states as the details sheet's thumbnails.
class ReceiptImage extends StatefulWidget {
  const ReceiptImage({super.key, required this.cache, required this.groupId, required this.url});

  final ReceiptCache cache;
  final String groupId;
  final String url;

  @override
  State<ReceiptImage> createState() => _ReceiptImageState();
}

class _ReceiptImageState extends State<ReceiptImage> {
  final _loader = _ReceiptLoader();

  @override
  void initState() {
    super.initState();
    _loader.load(widget.cache, widget.url, widget.groupId,
        onChange: () => mounted ? setState(() {}) : null);
  }

  @override
  Widget build(BuildContext context) => switch (_loader.state) {
        _TileState.loaded => Image.file(_loader.file!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const _TileIcon(Icons.broken_image_outlined)),
        _TileState.loading => const _TileSpinner(),
        _TileState.offline => const _TileIcon(Icons.cloud_off_outlined),
        _TileState.failed => const _TileIcon(Icons.broken_image_outlined),
      };
}

/// Loads one receipt through the cache and classifies a failure under the
/// #119 policy: a connection failure is "offline" (expected), anything
/// else is unexpected and reported once.
class _ReceiptLoader {
  _TileState state = _TileState.loading;
  File? file;
  String? diagnostics;
  int _attempt = 0;

  Future<void> load(ReceiptCache cache, String url, String groupId,
      {required VoidCallback onChange}) async {
    final attempt = ++_attempt;
    state = _TileState.loading;
    diagnostics = null;
    onChange();
    try {
      final loaded = await cache.load(url, groupId: groupId);
      if (attempt != _attempt) return;
      file = loaded;
      state = _TileState.loaded;
    } catch (e, st) {
      if (attempt != _attempt) return;
      final error = ErrorReporter.instance.report(e, st, operation: 'Loading receipt $url');
      state = error.kind == ErrorKind.connection ? _TileState.offline : _TileState.failed;
      diagnostics = error.diagnostics;
    }
    onChange();
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.child, this.onTap});

  static const double size = 88;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(dimension: size, child: Center(child: child)),
        ),
      ),
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) =>
      Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant);
}

class _TileSpinner extends StatelessWidget {
  const _TileSpinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2));
}

/// The receipts full screen, one per page, zoomable.
Future<void> showReceiptViewer(
  BuildContext context, {
  required ReceiptCache cache,
  required String groupId,
  required List<ExpenseDocument> documents,
  int initialIndex = 0,
}) =>
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ReceiptViewer(
        cache: cache,
        groupId: groupId,
        documents: documents,
        initialIndex: initialIndex,
      ),
    ));

class _ReceiptViewer extends StatefulWidget {
  const _ReceiptViewer({
    required this.cache,
    required this.groupId,
    required this.documents,
    required this.initialIndex,
  });

  final ReceiptCache cache;
  final String groupId;
  final List<ExpenseDocument> documents;
  final int initialIndex;

  @override
  State<_ReceiptViewer> createState() => _ReceiptViewerState();
}

class _ReceiptViewerState extends State<_ReceiptViewer> {
  late final _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final count = widget.documents.length;
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text(count > 1 ? l10n.receiptViewerTitle(_index + 1, count) : l10n.receiptViewerSingle),
        ),
        body: PageView.builder(
          controller: _controller,
          itemCount: count,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) => _ReceiptPage(
            key: ValueKey(widget.documents[i].url),
            cache: widget.cache,
            groupId: widget.groupId,
            document: widget.documents[i],
          ),
        ),
      ),
    );
  }
}

class _ReceiptPage extends StatefulWidget {
  const _ReceiptPage({super.key, required this.cache, required this.groupId, required this.document});

  final ReceiptCache cache;
  final String groupId;
  final ExpenseDocument document;

  @override
  State<_ReceiptPage> createState() => _ReceiptPageState();
}

class _ReceiptPageState extends State<_ReceiptPage> {
  final _loader = _ReceiptLoader();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => _loader.load(widget.cache, widget.document.url, widget.groupId,
      onChange: () => mounted ? setState(() {}) : null);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: switch (_loader.state) {
        _TileState.loaded => InteractiveViewer(
            maxScale: 6,
            child: Image.file(_loader.file!,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.broken_image_outlined, size: 48)),
          ),
        _TileState.loading => const CircularProgressIndicator(),
        _TileState.offline || _TileState.failed => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_loader.state == _TileState.offline)
                  Text(l10n.receiptAvailableWhenOnline, textAlign: TextAlign.center)
                else
                  ErrorMessage(l10n.receiptLoadFailed,
                      diagnostics: _loader.diagnostics, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
              ],
            ),
          ),
      },
    );
  }
}
