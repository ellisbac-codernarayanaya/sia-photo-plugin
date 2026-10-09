# Sia technical review handoff

## Product request

A familiar photo gallery for Android and iPhone that automatically backs up ordinary camera captures to Sia and retrieves the originals. The owner wants to send this source to Sia for review before native testing and distribution.

## Implementation boundaries

One Flutter application with Android and iOS integrations. Local camera-library capture is followed by asynchronous backup; direct replacement of the system Photos storage backend is not implemented. The current endpoint is https://sia.storage, using sia_storage 0.3.1.

## Requested review

1. Validate SDK account approval, recovery derivation, app identity, and compatibility with current Sia Storage services. Replace the placeholder service URL https://localhost/sia-photos before distribution.
2. Confirm upload/pin semantics, durable storage guarantees, encrypted metadata handling, catalog cursor semantics, and deletion events.
3. Review interruption recovery across upload, pin persistence and download verification. An upload interrupted before its object ID is persisted may leave an orphan requiring reconciliation.
4. Review packed-upload economics, large-video memory use, bandwidth from full verification downloads, and continued storage/payment requirements. No cheaper-than-iCloud/Google claim has been validated.
5. Review keychain/keystore handling, recovery and device migration, database account binding, and secure temporary-file/cache lifecycle. Local downloaded originals and the local database require a device-security review.
6. Compile both native targets and inspect the Rust bridge/toolchain integration, permissions, iOS entitlements and Android worker registration.
7. On real devices, assess background scheduling, limited photo access, force-stop, network loss, low storage, large videos, duplicate media and app reinstall/recovery.
8. Confirm media fidelity and document treatment of Live Photos, RAW pairs, edits, metadata and cloud-only originals before expanding feature claims.

## Validation status

Earlier development checks covered core backup policy and verification sequencing, and Dart analysis reported no errors or warnings at that point. Subsequent account-binding edits have not been checked. No native Android/iOS build, live account transfer, security audit, or device validation is claimed. Additional testing was stopped at the owner's request.

## Review outcome sought

Identify compatibility and security corrections; establish a working native build on both platforms; then agree on device acceptance checks, operating costs and the route to signed distribution.
