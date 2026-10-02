# Store assets

What the store listings need (#112), ready to upload. The listing text is in [listing.md](listing.md).

| File | Store | Size |
|---|---|---|
| `play-icon-512.png` | Google Play icon | 512×512 |
| `feature-graphic.png` | Google Play feature graphic | 1024×500 |
| `screenshots/play/*.png` | Google Play phone screenshots, in order | 1200×2400 |
| `app-store-icon-1024.png` | App Store icon | 1024×1024 |
| `screenshots/app-store/*.png` | App Store iPhone 6.9" screenshots, in order | 1320×2868 |

The icons come from `scripts/make_icons.py`. The screenshots and the feature graphic come from `scripts/make_store_assets.py`, which frames the raw captures in `screenshots/raw/` with a caption (its `CAPTIONS`) and draws the feature graphic. Play needs the 2:1 canvas: it rejects screenshots whose long side is more than twice the short one, and a 1080×2400 phone screen is 2.22:1.

## Taking the raw captures

Only made-up data, never a real group. The app had these groups joined, all on spliit.app:

- **Rockies Road Trip** (USD; John, Jane, Jack), the demo group reviewers get: https://spliit.app/groups/Lh7eRlfTFBoa_DVEL7mxO. The active user is John.
- **Flat 4B** (EUR): https://spliit.app/groups/3k_YJ7EBaJ1KgsfqHngSn
- **Book club** (USD): https://spliit.app/groups/YC2rwHoVLMYZ9GZtwGZUS
- **Lisbon 2025** (EUR), archived: https://spliit.app/groups/pNu1DseGcykygTLeeBTXp

One group is a favorite: Rockies Road Trip on Android, Flat 4B on iPhone. The simulator reports no network to the app, so a favorite with receipts shows a red 📎 there.

- **Android:** a release build on the `Medium_Phone` emulator (1080×2400), `adb exec-out screencap -p`. Demo mode gives the clean status bar: `settings put global sysui_demo_allowed 1`, then `am broadcast -a com.android.systemui.demo -e command …` with `enter`, `clock -e hhmm 0941`, `battery -e level 100 -e plugged false`, `network -e mobile hide -e wifi show -e level 4`, `notifications -e visible false`. Clear any notification first.
- **iPhone:** the iPhone 17 Pro Max simulator (1320×2868), `xcrun simctl io <device> screenshot`, with `xcrun simctl status_bar <device> override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`. Simulator builds are debug builds, so set `debugShowCheckedModeBanner: false` on `MaterialApp` for the capture only; don't commit it.

The add-expense shots are of an unsaved form, discarded afterwards.
