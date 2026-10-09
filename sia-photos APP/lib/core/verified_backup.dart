/// Commits a backup only after a durable remote pin and a byte-for-byte check.
/// A saved pin is reused after interruption; verification never reuploads it.
Future<void> commitBackup({
  required String expectedHash,
  String? pinnedId,
  required Future<String> Function() uploadAndPin,
  required Future<void> Function(String) rememberPin,
  required Future<String> Function(String) downloadHash,
  required Future<void> Function(String) markVerified,
}) async {
  final id = pinnedId ?? await uploadAndPin();
  if (pinnedId == null) await rememberPin(id);
  final actual = await downloadHash(id);
  if (actual != expectedHash) {
    throw StateError('Backup verification failed: downloaded content differs.');
  }
  await markVerified(id);
}
