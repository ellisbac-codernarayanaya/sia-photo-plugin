# Sia Photos — review prototype

Flutter source project for Android and iPhone. Independent project; not endorsed by Sia.

## Status

This delivery is source code for technical review, not an APK, signed iPhone app, or production release. Native compilation and live Sia transfers have not been verified. No further tests were run for this handoff, as requested by the owner. Included checks are available for the receiving team.

## Intended experience

Take photos with the phone's normal camera. After permission and account setup, this app detects accessible local photos and videos and queues them for backup through the Sia Storage SDK. Browse the gallery, inspect backup status, and retrieve originals.

Implemented source includes:
- Sia account approval and recovery-phrase setup.
- Secure local app-key storage and local database account binding.
- Photo/video discovery, optional existing-library backup, and Wi-Fi-only uploads.
- Android media-change scheduling and periodic fallback; iOS background processing registration.
- Persistent upload queue, retries, and worker lease.
- Packed uploads, pinned-object persistence, and downloaded SHA-256 verification before marking backup verified.
- Encrypted SDK metadata with thumbnails and a catalog recovery path.
- Photo viewing, video playback, filename/date search, and saving retrieved media to the device.

## Important behavior and limits

This is a companion gallery and backup app. It does not replace the operating system camera or redirect its storage directly to Sia. Captures are saved locally first and then queued. Originals are never automatically deleted.

Background execution depends on the phone OS. Immediate upload after every capture cannot be guaranteed, especially on iPhone. Force-stop, battery policy, network availability, and permissions can delay backup. iCloud-only originals must first be downloaded to the phone.

The app uses the Sia Storage SDK and the configured indexer at https://sia.storage. Although storage uses Sia, the current account/catalog access path depends on that service; this is not an entirely server-independent implementation.

Recovering the catalog requires the same Sia account, recovery phrase, and app identity. Metadata is specific to this app and is not automatically compatible with another Sia gallery.

Full Apple/Google Photos feature parity is outside this prototype: no face recognition, editing suite, shared albums, Google Photos account import, or complete Live Photo/RAW-pair preservation. Storage price savings have not been measured. Replication, small batches, and verification downloads affect costs.

## Build handoff

Use a development machine or hosted build runner with Flutter 3.47.6 and the native tools. Dependency versions are captured in pubspec.lock. The sia_storage dependency builds native Rust code; its toolchain and platform prerequisites must also be available. The Rust bridge is pinned to 2.12.0 to match the SDK.

Android: Java 17, Android SDK and NDK required by the Flutter/Gradle configuration, minimum Android API 26.

~~~sh
flutter pub get
flutter build apk --debug --target-platform android-arm64
~~~

Expected development APK: build/app/outputs/flutter-apk/app-debug.apk. This command has not been run successfully for this delivery. A store release needs an owner-controlled signing key and release configuration.

iPhone: a Mac or hosted macOS runner with full Xcode and the SDK's native prerequisites; deployment target iOS 15.

~~~sh
flutter pub get
flutter build ios --debug --no-codesign
~~~

An unsigned build is not directly installable on an iPhone. Open ios/Runner.xcworkspace in Xcode, select an Apple development team and appropriate bundle identifier, and configure signing/provisioning for device installation or TestFlight. Preserve background processing identifiers and keychain entitlements.

Neither build command runs the included test suite. Build troubleshooting and device review remain with the receiving team.

## Source map

- lib/main.dart: setup, gallery, settings, viewer and restore UI.
- lib/services/backup.dart: scheduling, discovery and transfer queue.
- lib/services/sia_account.dart: account connection, catalog metadata and retrieval.
- lib/services/store.dart: SQLite persistence and worker lease.
- lib/core/: backup state and verification policy.
- android/ and ios/: native project configuration.
- test/: included policy and verification checks.

See REVIEW_NOTES.md for the review priorities.
