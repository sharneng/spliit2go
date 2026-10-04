#!/bin/sh
# Writes BuildInfo.plist into the app with the commit this build is
# from, for About (#176): the full hash, with "-dirty" when tracked
# files have uncommitted changes, or "?" when git couldn't tell; empty
# without git. Run by the Runner target's "Build Info" phase on every
# build (alwaysOutOfDate), since git state isn't an input Xcode tracks.
# Its own file rather than a key in the processed Info.plist, which
# Xcode may still be writing while scripts run. See
# docs/decisions/build-info.md.
set -u

OUT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BuildInfo.plist"
COMMIT=""
if command -v git >/dev/null 2>&1 && SHA="$(git -C "$SRCROOT" rev-parse HEAD 2>/dev/null)"; then
  git -C "$SRCROOT" diff --quiet HEAD -- 2>/dev/null
  case $? in
    0) COMMIT="$SHA" ;;
    1) COMMIT="$SHA-dirty" ;;
    *) COMMIT="$SHA?" ;;
  esac
fi
case "$COMMIT" in
  "" | *"?") echo "warning: Couldn't read the git commit; About will show it as unknown." ;;
esac

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>GitCommit</key>
	<string>$COMMIT</string>
</dict>
</plist>
PLIST
