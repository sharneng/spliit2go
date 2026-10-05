import 'package:flutter/foundation.dart';

/// Spliit's and spliit-ios's MIT notices, shown on the licenses page next to
/// the packages' own (#109).
///
/// Spliit2Go is a Dart rewrite, but some rules were ported closely from
/// Spliit's source (the share math, date sections, the expense form's live
/// amounts) and from spliit-ios's (the receipt parser, group monograms, the
/// "Paid for" wording, the accent and money colors, the treatment of
/// amounts). Both licenses ask that their notice travel with
/// substantial portions of the software. THIRD_PARTY_NOTICES.md carries the
/// same notices in the repo.
void registerUpstreamLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() => Stream.fromIterable(upstreamLicenses));
}

bool _registered = false;

// The two notices differ by one phrase: Spliit's adds "(including the next
// paragraph)". Each is reproduced as its repo has it, line breaks aside.
const _mitGrant = '''
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:''';

const _mitWarranty = '''
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''';

/// The entries, as the licenses page lists them under "Spliit" and
/// "spliit-ios".
final upstreamLicenses = <LicenseEntry>[
  const LicenseEntryWithLineBreaks(['Spliit'], '''
Parts of Spliit2Go are adapted from Spliit (https://github.com/spliit-app/spliit).

MIT License

Copyright (c) 2023 Sebastien Castiel
$_mitGrant

The above copyright notice and this permission notice (including the next paragraph) shall be included in all copies or substantial portions of the Software.
$_mitWarranty'''),
  const LicenseEntryWithLineBreaks(['spliit-ios'], '''
Parts of Spliit2Go are adapted from spliit-ios (https://github.com/spliit-app/spliit-ios).

MIT License

Copyright (c) 2026 Sebastien Castiel
$_mitGrant

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
$_mitWarranty'''),
];
