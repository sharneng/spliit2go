# Spliit2Go privacy policy

Last updated on October 2, 2026.

Spliit2Go is an unofficial, community-made mobile app for [Spliit](https://spliit.app), the free and open-source app for sharing expenses. It isn't affiliated with or endorsed by the Spliit project. Its source code is public at [github.com/sharneng/spliit2go](https://github.com/sharneng/spliit2go). This policy describes what the app keeps on your phone, what leaves it, and where it goes.

## In short

- Spliit2Go has no accounts and no ads, and its developers collect nothing: no analytics, no crash reports.
- Your groups and expenses go to the Spliit server the group lives on (spliit.app unless you chose another), and are covered by that server's privacy policy.
- On Android, receipt scanning reads the photo on your phone. The photo isn't sent to Google, but Google's ML Kit, which does the reading, sends Google some diagnostic data (see below).

## What stays on your phone

The app keeps, on your phone only:

- a copy of the groups you join or create: their names, currencies and participants, and their expenses, so you can use them offline;
- for each group, which participant you are, and the name you gave the first time, to suggest it in other groups;
- expenses and receipt photos you added offline, until they are uploaded;
- copies of receipts you opened, and of your favorite groups' receipts if you turned that on, within the storage limit you set;
- your settings: theme, language, how your group list is sorted, the receipt languages you picked, and the receipt download settings.

Errors the app didn't expect are written to the phone's own log, which stays on the phone.

Your phone's own backup (Android's backup to your Google account, or iCloud on an iPhone) may include this data, depending on your phone's settings. Those backups are kept by Google or Apple under your account, not by Spliit2Go, and you manage them in your phone's or account's settings.

## What goes to your Spliit server

Spliit2Go is a client: it reads and changes your groups on the Spliit server each group was created on.

- **Group data:** when you view a group, the app downloads it from the server; when you add, edit or delete an expense, change a group's settings, or create a group, it sends that to the server.
- **Receipt photos:** photos you attach are made smaller and have all their embedded metadata removed, including where they were taken, before they are uploaded to the server's file storage.
- Like any app that uses the internet, your phone's IP address is visible to the server it connects to.
- **Security:** the app talks to spliit.app over HTTPS, which encrypts the connection. For another server it uses the address you entered, which is encrypted when it starts with `https://`.

The default server is spliit.app, operated by Sebastien Castiel, and its [privacy policy](https://spliit.app/privacy) applies to what is stored there. If you use a group on another Spliit server, that server's operator decides what happens to it. On Spliit, anyone with a group's link can see and change the group, so share links only with people you trust.

## Receipt scanning (Android)

Scan receipt uses Google's [ML Kit](https://developers.google.com/ml-kit) and the Document Scanner from Google Play services, both running on your phone. The photo and the text read from it are not sent to Google or anyone else: the app only fills in the expense form with what it read.

Google Play services downloads the Document Scanner, and the text recognition models for Chinese and Japanese, from Google. So that the first scan works offline, the app asks for the Document Scanner, and for your phone's language's model if it is Chinese or Japanese, in the background when it starts; the other model downloads when you pick its language. The Latin-script model is built into the app. ML Kit also sends Google diagnostic and usage data: the device's make, model and Android version, the app's package name and version, performance figures such as how long a scan took, the image format and resolution, and an identifier for the installation that is not meant to identify you. It is encrypted in transit and is not shared with third parties ([Google's disclosure](https://developers.google.com/ml-kit/android-data-disclosure)). Spliit2Go doesn't receive any of it.

Receipt scanning isn't available on iPhone yet.

## Permissions

- **Camera and photos:** only when you take or choose a receipt photo.
- **Internet:** to talk to your Spliit servers.

Sharing a group's link goes through your phone's share sheet, only when you tap Share. Links on the About screen open in your browser.

## Keeping and removing your data

What the app keeps on your phone stays there until you remove it or uninstall the app; copies of receipts are also removed as needed to stay under the storage limit you set.

- Removing a group from the app's group list deletes its copy on your phone, including its stored receipts. Clear, under Storage in App settings, deletes stored receipts. Uninstalling the app deletes everything it kept on the phone.
- Neither removing data in the app nor uninstalling it deletes your phone's backups. A backup that includes the app's data can still hold it afterwards, and Android restores it when you install the app again. To remove it there, delete the backup, or the app's data in it, in your phone's or account's backup settings ([Android](https://support.google.com/android/answer/2819582), [iCloud](https://support.apple.com/108922)).
- Data on a Spliit server stays there when you remove a group from the app. For spliit.app, see its [privacy policy](https://spliit.app/privacy); for another server, ask its operator.

## Children

Spliit2Go isn't directed at children and doesn't knowingly collect anything from them.

## Changes

Changes to this policy are published at this address, with a new date at the top. Its history is in the [repository](https://github.com/sharneng/spliit2go/commits/main/docs/privacy.md).

## Contact

Questions about privacy, or anything else: email [support@sharneng.com](mailto:support@sharneng.com), or open an issue at [github.com/sharneng/spliit2go/issues](https://github.com/sharneng/spliit2go/issues).
