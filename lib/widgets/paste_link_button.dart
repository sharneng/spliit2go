import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/context_l10n.dart';
import '../services/error_reporting.dart';

const _channel = MethodChannel('com.sharneng.spliit2go/paste_link');

/// Whether the clipboard probably holds a link (#221), asked without
/// reading it: iOS shows no "pasted from" notice, Android no toast.
/// False if the platform can't tell.
Future<bool> clipboardProbablyHasLink() async {
  try {
    return await _channel.invokeMethod<bool>('probablyHasLink') ?? false;
  } on MissingPluginException {
    return false;
  } catch (e, st) {
    ErrorReporter.instance.report(e, st, operation: 'Checking the clipboard for a link');
    return false;
  }
}

/// Pastes the clipboard's text into [onPaste] (#221). On iOS it's Apple's
/// own paste button (`UIPasteControl`, ios/Runner/PasteLink.swift): iOS
/// trusts it, where an app's own button reading the clipboard is asked
/// "Allow Paste?" every time. On Android it's ours: reading there needs
/// no permission.
class PasteLinkButton extends StatelessWidget {
  const PasteLinkButton({super.key, required this.onPaste});

  final ValueChanged<String> onPaste;

  /// Apple's button draws at this size; Android's is an [IconButton].
  static const size = 36.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (defaultTargetPlatform == TargetPlatform.iOS && !kIsWeb) {
      return Semantics(
        // Apple's button speaks for itself.
        container: true,
        child: SizedBox.square(
          dimension: size,
          child: UiKitView(
            viewType: 'com.sharneng.spliit2go/paste_button',
            creationParams: {
              'background': scheme.primary.toARGB32(),
              'foreground': scheme.onPrimary.toARGB32(),
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: (id) => MethodChannel('com.sharneng.spliit2go/paste_button_$id')
                .setMethodCallHandler((call) async {
              if (call.method == 'pasted' && call.arguments is String) onPaste(call.arguments as String);
            }),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: context.l10n.joinGroupPasteLink,
      icon: const Icon(Icons.content_paste),
      onPressed: () async {
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (text != null && text.trim().isNotEmpty) onPaste(text);
      },
    );
  }
}
