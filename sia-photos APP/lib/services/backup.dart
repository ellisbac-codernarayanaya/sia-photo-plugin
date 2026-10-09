import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sia_storage/sia_storage.dart';
import 'package:workmanager/workmanager.dart';
import '../core/backup_policy.dart';
import '../core/verified_backup.dart';
import 'sia_account.dart';
import 'store.dart';

const periodicTask = 'dev.personal.siaPhotos.refresh';
const processingTask = 'dev.personal.siaPhotos.processing';
const photoPermission = PermissionRequestOption(
  androidPermission: AndroidPermission(
    type: RequestType.common,
    mediaLocation: true,
  ),
);

@pragma('vm:entry-point')
void backupDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    final store = await Store.open();
    if (!await store.get<bool>('enabled', false)) return true;
    try {
      if (Platform.isAndroid && task == 'photo-change') {
        await BackupSchedule.watch(store, 1 - ((input?['slot'] as int?) ?? 0));
      }
      if (Platform.isIOS) await BackupSchedule.scheduleIos(store);
      return await BackupService(store).run(background: true);
    } catch (_) {
      await store.set(
        'message',
        'Backup could not finish. It will retry; your originals are still on your phone.',
      );
      return false;
    }
  });
}

class BackupSchedule {
  static Future<Constraints> constraints(Store store) async => Constraints(
    networkType: await store.get<bool>('wifi-only', true)
        ? NetworkType.unmetered
        : NetworkType.connected,
    requiresBatteryNotLow: true,
    requiresStorageNotLow: true,
  );
  static Future<void> configure(Store store) async {
    if (!await store.get<bool>('enabled', false)) {
      await Workmanager().cancelAll();
      return;
    }
    if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        periodicTask,
        'backup',
        frequency: const Duration(minutes: 15),
        constraints: await constraints(store),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
      await watch(store, 0);
      await now(store);
    } else if (Platform.isIOS) {
      await scheduleIos(store);
    }
  }

  static Future<void> scheduleIos(Store store) async {
    final rule = await constraints(store);
    rule.networkType = NetworkType.connected;
    await Workmanager().registerProcessingTask(
      processingTask,
      processingTask,
      initialDelay: const Duration(minutes: 15),
      constraints: rule,
    );
  }

  static Future<void> watch(Store store, int slot) async {
    if (!await store.get<bool>('enabled', false)) return;
    final rule = await constraints(store);
    rule.contentUriTriggers = [
      ContentUriTrigger(
        uri: 'content://media/external/images/media',
        triggerForDescendants: true,
      ),
      ContentUriTrigger(
        uri: 'content://media/external/video/media',
        triggerForDescendants: true,
      ),
    ];
    // Alternate names so rearming does not cancel the worker currently uploading.
    await Workmanager().registerOneOffTask(
      'photo-watch-$slot',
      'photo-change',
      inputData: {'slot': slot},
      constraints: rule,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 1),
    );
  }

  static Future<void> now(Store store) async =>
      Workmanager().registerOneOffTask(
        'backup-now',
        'backup',
        constraints: await constraints(store),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
}

class BackupService {
  final Store store;
  BackupService(this.store);
  Future<void> scan() async {
    final permission = await PhotoManager.getPermissionState(
      requestOption: photoPermission,
    );
    if (!permission.hasAccess) {
      throw StateError(
        'Allow photo access in Settings to back up your camera roll.',
      );
    }
    await store.set('limited-access', !permission.isAuth);
    final all = await store.get<bool>('include-existing', false);
    final started = DateTime.fromMillisecondsSinceEpoch(
      await store.get<int>('started', DateTime.now().millisecondsSinceEpoch),
    );
    final filter = FilterOptionGroup(
      createTimeCond: DateTimeCond(
        min: all ? DateTime.fromMillisecondsSinceEpoch(0) : started,
        max: DateTime.now().add(const Duration(days: 1)),
      ),
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
    );
    for (var page = 0; ; page++) {
      final assets = await PhotoManager.getAssetListPaged(
        page: page,
        pageCount: 200,
        type: RequestType.common,
        filterOption: filter,
      );
      for (final asset in assets) {
        await store.enqueue(
          PhotoEntry(
            key: assetVersion(asset.id, asset.modifiedDateTime),
            assetId: asset.id,
            name: await asset.titleAsync,
            taken: asset.createDateTime,
            video: asset.type == AssetType.video,
            state: 'pending',
          ),
        );
      }
      if (assets.length < 200) break;
    }
  }

  Future<bool> networkAllowed() async {
    final kinds = await Connectivity().checkConnectivity();
    if (kinds.contains(ConnectivityResult.none)) return false;
    if (!await store.get<bool>('wifi-only', true)) return true;
    return kinds.contains(ConnectivityResult.wifi) ||
        kinds.contains(ConnectivityResult.ethernet);
  }

  Future<bool> run({bool background = false}) async {
    if (!await store.get<bool>('enabled', false) ||
        !await SiaAccount.hasAccount()) {
      return true;
    }
    final lease = await store.acquireLease();
    if (lease == null) return true;
    final heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(store.renewLease(lease));
    });
    final started = DateTime.now();
    try {
      await store.set('message', 'Looking for new photos…');
      await scan();
      if (!await networkAllowed()) {
        await store.set(
          'message',
          await store.get<bool>('wifi-only', true)
              ? 'Waiting for Wi-Fi. Your photos are queued.'
              : 'Waiting for an internet connection.',
        );
        return true;
      }
      final sdk = await SiaAccount.connect();
      await SiaAccount.syncCatalog(sdk, store);
      var failed = false;
      do {
        if (!await store.get<bool>('enabled', false) ||
            !await networkAllowed()) {
          break;
        }
        final pending = await store.pending();
        if (pending.isEmpty) break;
        final fresh = <PhotoEntry>[];
        for (final photo in pending) {
          if (photo.objectId != null) {
            try {
              await verify(sdk, photo);
            } catch (_) {
              await store.fail(
                photo,
                'Could not verify the saved copy. Will retry.',
              );
              failed = true;
            }
          } else {
            fresh.add(photo);
          }
        }
        if (fresh.isNotEmpty) failed = !await uploadBatch(sdk, fresh) || failed;
        if (background &&
            DateTime.now().difference(started) > const Duration(minutes: 4)) {
          break;
        }
      } while (true);
      final counts = await store.counts();
      final waiting =
          (counts['pending'] ?? 0) +
          (counts['pinned'] ?? 0) +
          (counts['uploading'] ?? 0);
      await store.set('last-run', DateTime.now().millisecondsSinceEpoch);
      await store.set(
        'message',
        failed
            ? 'Some items need another attempt. Originals are safe on your phone.'
            : waiting > 0
            ? '$waiting items waiting for the next backup.'
            : 'Backup checked. New photos will be picked up automatically.',
      );
      return !failed;
    } catch (_) {
      await store.set(
        'message',
        'Backup is waiting. Check photo access, your connection, and your Sia storage allowance.',
      );
      return false;
    } finally {
      heartbeat.cancel();
      await store.releaseLease(lease);
    }
  }

  Future<String> readBackHash(Sdk sdk, PhotoEntry photo) async {
    await store.set('message', 'Verifying ${photo.name}…');
    final file = await SiaAccount.downloadVerified(sdk, photo);
    try {
      return (await sha256.bind(file.openRead()).first).toString();
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> verify(Sdk sdk, PhotoEntry photo) => commitBackup(
    expectedHash: photo.hash!,
    pinnedId: photo.objectId!,
    uploadAndPin: () async => throw StateError('Expected an existing pin.'),
    rememberPin: (_) async {},
    downloadHash: (_) => readBackHash(sdk, photo),
    markVerified: (_) => store.update(photo.key, {
      'state': 'verified',
      'error': null,
      'attempts': 0,
      'retry_at': 0,
    }),
  );

  Future<bool> uploadBatch(Sdk sdk, List<PhotoEntry> candidates) async {
    final cache = await getTemporaryDirectory();
    final folder = await Directory('${cache.path}/upload-').createTemp();
    final ready =
        <
          ({PhotoEntry photo, File file, String hash, int size, String? thumb})
        >[];
    var total = 0;
    var success = true;
    try {
      for (final photo in candidates) {
        if (!await store.get<bool>('enabled', false)) break;
        try {
          final asset = photo.assetId == null
              ? null
              : await AssetEntity.fromId(photo.assetId!);
          if (asset == null) {
            await store.update(photo.key, {
              'state': 'missing',
              'error': 'Original is no longer available on this phone.',
            });
            continue;
          }
          if (!await asset.isLocallyAvailable()) {
            await store.fail(
              photo,
              'Original is in iCloud. Download it to this phone before backup.',
            );
            success = false;
            continue;
          }
          final original = await asset.originFile;
          if (original == null) {
            throw StateError('Original is not readable yet.');
          }
          final snapshot = await original.copy(
            '${folder.path}/${ready.length}',
          );
          final hash = (await sha256.bind(snapshot.openRead()).first)
              .toString();
          final size = await snapshot.length();
          final existing = await store.verifiedObject(hash);
          if (existing != null) {
            await store.update(photo.key, {
              'hash': hash,
              'bytes': size,
              'object_id': existing,
              'state': 'verified',
              'error': null,
            });
            await snapshot.delete();
            continue;
          }
          if (ready.any((item) => item.hash == hash)) {
            await snapshot.delete();
            continue;
          }
          await store.update(photo.key, {
            'state': 'uploading',
            'hash': hash,
            'bytes': size,
            'error': null,
          });
          String? thumb;
          try {
            final bytes = await asset.thumbnailDataWithSize(
              const ThumbnailSize.square(240),
              quality: 40,
            );
            if (bytes != null && bytes.length <= 24000)
              thumb = base64Encode(bytes);
          } catch (_) {}
          await store.update(photo.key, {'thumbnail': thumb});
          ready.add((
            photo: photo,
            file: snapshot,
            hash: hash,
            size: size,
            thumb: thumb,
          ));
          total += size;
          if (total >= 80 * 1024 * 1024) break;
        } catch (_) {
          await store.fail(photo, 'Could not read the original. Will retry.');
          success = false;
        }
      }
      if (ready.isEmpty) return success;
      await store.set(
        'message',
        'Encrypting and uploading ${ready.length} items…',
      );
      final packed = sdk.uploadPacked(
        options: const UploadOptions(maxBufferedSlabs: 1),
      );
      for (final item in ready) {
        await packed.upload.add(item.file.openRead());
      }
      final objects = await packed.upload.finalize();
      if (objects.length != ready.length) {
        throw StateError('Unexpected upload result.');
      }
      for (var i = 0; i < ready.length; i++) {
        final item = ready[i];
        try {
          objects[i].updateMetadata(
            metadata: utf8.encode(
              jsonEncode(
                SiaAccount.photoMetadata(
                  item.photo,
                  item.hash,
                  item.size,
                  item.thumb,
                ),
              ),
            ),
          );
          await commitBackup(
            expectedHash: item.hash,
            uploadAndPin: () async {
              await sdk.pinObject(object: objects[i]);
              return objects[i].id();
            },
            rememberPin: (id) => store.update(item.photo.key, {
              'object_id': id,
              'state': 'pinned',
            }),
            downloadHash: (id) => readBackHash(
              sdk,
              PhotoEntry(
                key: item.photo.key,
                name: item.photo.name,
                taken: item.photo.taken,
                video: item.photo.video,
                state: 'pinned',
                objectId: id,
                hash: item.hash,
                bytes: item.size,
              ),
            ),
            markVerified: (_) => store.update(item.photo.key, {
              'state': 'verified',
              'error': null,
              'attempts': 0,
              'retry_at': 0,
            }),
          );
        } catch (_) {
          await store.fail(
            item.photo,
            'Upload or verification was interrupted. Will retry.',
          );
          success = false;
        }
      }
      return success;
    } catch (_) {
      for (final item in ready) {
        await store.fail(item.photo, 'Upload interrupted. Waiting to retry.');
      }
      return false;
    } finally {
      if (await folder.exists()) await folder.delete(recursive: true);
    }
  }
}
