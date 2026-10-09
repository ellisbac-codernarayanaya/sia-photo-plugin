import 'package:sia_photos/core/backup_policy.dart';
import 'package:sia_photos/core/verified_backup.dart';

void expectEqual(Object? actual, Object? expected, String label) {
  if (actual != expected) {
    throw StateError('$label: expected $expected, got $actual');
  }
}

Future<void> expectFailure(Future<void> Function() action) async {
  var failed = false;
  try {
    await action();
  } catch (_) {
    failed = true;
  }
  if (!failed) throw StateError('Expected an error to propagate.');
}

Future<int> runBackupChecks() async {
  var checks = 0;
  final t = DateTime.utc(2026, 10, 8, 10);
  expectEqual(
    eligibleForBackup(
      created: t.subtract(const Duration(seconds: 1)),
      started: t,
      includeExisting: false,
    ),
    false,
    'older photos excluded',
  );
  checks++;
  expectEqual(
    eligibleForBackup(created: t, started: t, includeExisting: false),
    true,
    'start boundary included',
  );
  checks++;
  expectEqual(
    eligibleForBackup(
      created: t.subtract(const Duration(days: 20)),
      started: t,
      includeExisting: true,
    ),
    true,
    'existing library opt-in',
  );
  checks++;
  expectEqual(
    assetVersion('same', t) ==
        assetVersion('same', t.add(const Duration(seconds: 1))),
    false,
    'edited assets get another version',
  );
  checks++;
  expectEqual(
    safeFilename('../../a.jpg').contains('/'),
    false,
    'directory traversal removed',
  );
  checks++;
  expectEqual(
    safeFilename(r'C:\photos\private.jpg').contains(r'\'),
    false,
    'backslash removed',
  );
  checks++;
  expectEqual(safeFilename('..'), 'photo', 'parent path rejected');
  checks++;
  expectEqual(retryDelay(100), const Duration(minutes: 360), 'backoff capped');
  checks++;
  expectEqual(
    stateAfterVerification('original', 'changed'),
    BackupState.failed,
    'different bytes are never verified',
  );
  checks++;
  expectEqual(
    stateAfterVerification('same', 'same'),
    BackupState.verified,
    'matching bytes verify',
  );
  checks++;

  final events = <String>[];
  await commitBackup(
    expectedHash: 'hash',
    uploadAndPin: () async {
      events.add('pin');
      return 'object-1';
    },
    rememberPin: (id) async {
      events.add('persist:$id');
    },
    downloadHash: (id) async {
      events.add('download:$id');
      return 'hash';
    },
    markVerified: (id) async {
      events.add('verified:$id');
    },
  );
  expectEqual(
    events.join(','),
    'pin,persist:object-1,download:object-1,verified:object-1',
    'pin is persisted before verification',
  );
  checks++;

  events.clear();
  await expectFailure(
    () => commitBackup(
      expectedHash: 'hash',
      uploadAndPin: () async => throw StateError('offline'),
      rememberPin: (_) async {
        events.add('persist');
      },
      downloadHash: (_) async {
        events.add('download');
        return 'hash';
      },
      markVerified: (_) async {
        events.add('verified');
      },
    ),
  );
  expectEqual(events.isEmpty, true, 'failed upload cannot commit anything');
  checks++;

  events.clear();
  await expectFailure(
    () => commitBackup(
      expectedHash: 'hash',
      uploadAndPin: () async => 'object-1',
      rememberPin: (_) async => throw StateError('disk full'),
      downloadHash: (_) async {
        events.add('download');
        return 'hash';
      },
      markVerified: (_) async {
        events.add('verified');
      },
    ),
  );
  expectEqual(events.isEmpty, true, 'disk failure stops before success');
  checks++;

  String? durableId;
  var uploads = 0;
  await expectFailure(
    () => commitBackup(
      expectedHash: 'hash',
      uploadAndPin: () async {
        uploads++;
        return 'object-1';
      },
      rememberPin: (id) async {
        durableId = id;
      },
      downloadHash: (_) async => throw StateError('interrupted'),
      markVerified: (_) async {
        events.add('verified');
      },
    ),
  );
  expectEqual(durableId, 'object-1', 'pin survives download interruption');
  checks++;
  expectEqual(events.isEmpty, true, 'interrupted verification is not success');
  checks++;
  await commitBackup(
    expectedHash: 'hash',
    pinnedId: durableId,
    uploadAndPin: () async {
      uploads++;
      return 'duplicate';
    },
    rememberPin: (_) async => throw StateError('must not replace saved pin'),
    downloadHash: (_) async => 'hash',
    markVerified: (id) async {
      events.add('verified:$id');
    },
  );
  expectEqual(uploads, 1, 'retry reuses pin without uploading again');
  checks++;
  expectEqual(
    events.single,
    'verified:object-1',
    'retry verifies original object',
  );
  checks++;

  events.clear();
  await expectFailure(
    () => commitBackup(
      expectedHash: 'original',
      pinnedId: 'object-1',
      uploadAndPin: () async => throw StateError('unexpected upload'),
      rememberPin: (_) async {},
      downloadHash: (_) async => 'corrupt',
      markVerified: (_) async {
        events.add('verified');
      },
    ),
  );
  expectEqual(events.isEmpty, true, 'corruption never commits verified');
  checks++;
  final photo = PhotoEntry(
    key: 'asset@123',
    assetId: 'asset',
    name: 'IMG.jpg',
    taken: t,
    video: false,
    state: 'pinned',
    objectId: 'object-1',
    hash: 'hash',
    bytes: 100,
  );
  final recovered = PhotoEntry.fromMap(photo.toMap());
  expectEqual(
    recovered.objectId,
    'object-1',
    'object ID survives journal serialization',
  );
  checks++;
  expectEqual(
    recovered.hash,
    'hash',
    'verification digest survives serialization',
  );
  checks++;
  return checks;
}

Future<void> main() async {
  final checks = await runBackupChecks();
  // ignore: avoid_print
  print('$checks backup correctness checks passed.');
}
