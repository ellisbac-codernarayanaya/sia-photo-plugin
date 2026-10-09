enum BackupState { pending, uploading, pinned, verified, failed, missing }

String assetVersion(String id, DateTime modified) =>
    '$id@${modified.toUtc().millisecondsSinceEpoch}';

bool eligibleForBackup({
  required DateTime created,
  required DateTime started,
  required bool includeExisting,
}) => includeExisting || !created.isBefore(started);

Duration retryDelay(int failures) =>
    Duration(minutes: (1 << failures.clamp(0, 10)).clamp(1, 360));

String safeFilename(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_');
  return cleaned.isEmpty || cleaned == '.' || cleaned == '..'
      ? 'photo'
      : cleaned;
}

/// A pinned object is not a verified backup until its downloaded bytes match.
BackupState stateAfterVerification(String expected, String actual) =>
    expected == actual ? BackupState.verified : BackupState.failed;

class PhotoEntry {
  final String key;
  final String? assetId;
  final String name;
  final DateTime taken;
  final bool video;
  final String state;
  final String? hash;
  final String? objectId;
  final int bytes;
  final int attempts;
  final String? error;
  final String? thumbnail;

  const PhotoEntry({
    required this.key,
    this.assetId,
    required this.name,
    required this.taken,
    required this.video,
    required this.state,
    this.hash,
    this.objectId,
    this.bytes = 0,
    this.attempts = 0,
    this.error,
    this.thumbnail,
  });

  factory PhotoEntry.fromMap(Map<String, Object?> row) => PhotoEntry(
    key: row['key'] as String,
    assetId: row['asset_id'] as String?,
    name: row['name'] as String,
    taken: DateTime.fromMillisecondsSinceEpoch(row['taken'] as int),
    video: row['video'] == 1,
    state: row['state'] as String,
    hash: row['hash'] as String?,
    objectId: row['object_id'] as String?,
    bytes: row['bytes'] as int? ?? 0,
    attempts: row['attempts'] as int? ?? 0,
    error: row['error'] as String?,
    thumbnail: row['thumbnail'] as String?,
  );

  Map<String, Object?> toMap() => {
    'key': key,
    'asset_id': assetId,
    'name': name,
    'taken': taken.millisecondsSinceEpoch,
    'video': video ? 1 : 0,
    'state': state,
    'hash': hash,
    'object_id': objectId,
    'bytes': bytes,
    'attempts': attempts,
    'error': error,
    'thumbnail': thumbnail,
  };
}
