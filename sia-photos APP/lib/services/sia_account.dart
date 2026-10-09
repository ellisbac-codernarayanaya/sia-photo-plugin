import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sia_storage/sia_storage.dart';
import 'package:sqflite/sqflite.dart';
import '../core/backup_policy.dart';
import 'store.dart';

class SiaAccount {
  static const indexer = 'https://sia.storage';
  static const secure = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static final metadata = AppMetadata(
    id: Uint8List.fromList(
      sha256.convert(utf8.encode('dev.personal.sia_photos.v1')).bytes,
    ),
    name: 'Sia Photos — personal app',
    description:
        'Independent photo backup. Not an official Sia Foundation app.',
    serviceUrl: 'https://localhost/sia-photos',
  );

  static Future<bool> hasAccount() async =>
      await secure.read(key: 'app-key') != null;
  static Future<Builder> builder() =>
      Sia.builder(indexerUrl: indexer, appMeta: metadata);
  static Future<void> save(Sdk sdk, Store store) async {
    await store.bindAccount(sdk.appKey().publicKey());
    await secure.write(key: 'app-key', value: base64Encode(sdk.appKey().export_()));
  }

  static Future<Sdk> connect() async {
    final value = await secure.read(key: 'app-key');
    if (value == null) throw StateError('Connect your Sia account first.');
    final sdk = await (await builder()).connected(
      appKey: await Sia.appKey(base64Decode(value)),
    );
    if (sdk == null) {
      throw StateError(
        'Sia did not recognise this connection. Restore it with your recovery phrase.',
      );
    }
    await (await Store.open()).bindAccount(sdk.appKey().publicKey());
    return sdk;
  }

  static Map<String, Object?> photoMetadata(
    PhotoEntry photo,
    String hash,
    int size,
    String? thumbnail,
  ) => {
    'schema': 'sia-photos/1',
    'name': photo.name,
    'taken': photo.taken.toUtc().toIso8601String(),
    'video': photo.video,
    'sha256': hash,
    'bytes': size,
    'thumbnail': thumbnail,
  };

  /// Remote metadata lets another phone rebuild the library with the same key.
  static Future<void> syncCatalog(Sdk sdk, Store store) async {
    final id = await store.get<String>('cursor-id', '');
    final time = await store.get<String>('cursor-time', '');
    ObjectsCursor? cursor = id.isEmpty
        ? null
        : ObjectsCursor(id: id, after: DateTime.parse(time));
    while (true) {
      final events = await sdk.objectEvents(cursor: cursor, limit: 100);
      if (events.isEmpty) break;
      await store.db.transaction((txn) async {
        for (final event in events) {
          if (event.deleted) {
            await txn.update(
              'photos',
              {'state': 'missing', 'error': 'No longer in the Sia catalog.'},
              where: 'object_id = ?',
              whereArgs: [event.id],
            );
            continue;
          }
          final object = event.object;
          if (object == null) continue;
          Map<String, dynamic> data;
          try {
            data =
                jsonDecode(utf8.decode(object.metadata()))
                    as Map<String, dynamic>;
          } on FormatException {
            continue;
          } on TypeError {
            continue;
          }
          if (data['schema'] != 'sia-photos/1' ||
              data['sha256'] is! String ||
              data['name'] is! String ||
              data['taken'] is! String) {
            continue;
          }
          final taken = DateTime.tryParse(data['taken'] as String);
          if (taken == null) continue;
          final existing = await txn.query(
            'photos',
            where: 'object_id = ?',
            whereArgs: [event.id],
            limit: 1,
          );
          if (existing.isEmpty) {
            final photo = PhotoEntry(
              key: 'cloud:${event.id}',
              name: data['name'] as String,
              taken: taken,
              video: data['video'] == true,
              state: 'pinned',
              objectId: event.id,
              hash: data['sha256'] as String,
              bytes: object.size().toInt(),
              thumbnail:
                  data['thumbnail'] is String &&
                      (data['thumbnail'] as String).length <= 32000
                  ? data['thumbnail'] as String
                  : null,
            );
            await txn.insert(
              'photos',
              photo.toMap(),
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
          }
        }
        for (final pair in {
          'cursor-id': events.last.id,
          'cursor-time': events.last.updatedAt.toUtc().toIso8601String(),
        }.entries) {
          await txn.rawInsert(
            'INSERT OR REPLACE INTO settings(key,value) VALUES (?,?)',
            [pair.key, jsonEncode(pair.value)],
          );
        }
      });
      final next = ObjectsCursor(
        id: events.last.id,
        after: events.last.updatedAt,
      );
      if (cursor?.id == next.id && cursor?.after == next.after) {
        throw StateError('The Sia catalog did not advance. Try again later.');
      }
      cursor = next;
      if (events.length < 100) break;
    }
  }

  static Future<File> downloadVerified(Sdk sdk, PhotoEntry photo) async {
    if (photo.objectId == null || photo.hash == null) {
      throw StateError('This photo has not finished uploading.');
    }
    final cache = await getTemporaryDirectory();
    final file = File(
      '${cache.path}/${photo.objectId}-${safeFilename(photo.name)}',
    );
    if (await file.exists()) {
      if ((await sha256.bind(file.openRead()).first).toString() == photo.hash) {
        return file;
      }
      await file.delete();
    }
    final part = File(
      '${file.path}.part-${DateTime.now().microsecondsSinceEpoch}',
    );
    final sink = part.openWrite();
    try {
      final object = await sdk.object(key: photo.objectId!);
      await sink.addStream(
        sdk
            .download(
              object: object,
              options: const DownloadOptions(maxBufferedChunks: 4),
            )
            .data,
      );
      await sink.close();
      final digest = (await sha256.bind(part.openRead()).first).toString();
      if (stateAfterVerification(photo.hash!, digest) != BackupState.verified) {
        throw StateError(
          'Download did not match the original. Keep the original and retry.',
        );
      }
      return await part.rename(file.path);
    } catch (_) {
      await sink.close();
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }
}
