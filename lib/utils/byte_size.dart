import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../l10n/context_l10n.dart';

/// A storage size for people (#123): kilobytes under a megabyte, else
/// megabytes to one decimal, in the app's language ("12.3 MB", "12,3 Mo").
String formatByteSize(BuildContext context, int bytes) {
  final l10n = context.l10n;
  const kb = 1024, mb = 1024 * 1024;
  final locale = context.appLocale.toString();
  if (bytes < mb) {
    return l10n.bytesKilobytes(NumberFormat.decimalPattern(locale).format((bytes / kb).ceil()));
  }
  return l10n.bytesMegabytes(NumberFormat('#,##0.#', locale).format(bytes / mb));
}
