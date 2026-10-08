import 'package:flutter/services.dart' show appFlavor;

/// The app's name as its icon shows it: "Spliit2Go Dev" in the dev build,
/// which installs beside the real app, so the two can be told apart inside
/// too (#219, Kenneth). `appFlavor` is the build's `--flavor`, or
/// pubspec.yaml's default-flavor; tests have none, and get the real name.
const String appName = appFlavor == 'dev' ? 'Spliit2Go Dev' : 'Spliit2Go';
