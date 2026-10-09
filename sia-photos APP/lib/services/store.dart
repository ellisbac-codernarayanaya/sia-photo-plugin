import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../core/backup_policy.dart';

class Store {
  final Database db;
  Store(this.db);

  static Future<Store> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'sia_photos.db'),
      version: 2,
      onUpgrade: (db, old, next) async {
        if (old < 2)
          await db.execute('ALTER TABLE photos ADD COLUMN thumbnail TEXT');
      },
      onCreate: (db, version) async {
        await db.execute(
          '''CREATE TABLE photos (
          key TEXT PRIMARY KEY, asset_id TEXT, name TEXT NOT NULL,
          taken INTEGER NOT NULL, video INTEGER NOT NULL, state TEXT NOT NULL,
          hash TEXT, object_id TEXT, bytes INTEGER DEFAULT 0,
          attempts INTEGER DEFAULT 0, error TEXT, thumbnail TEXT, retry_at INTEGER DEFAULT 0)''',
        );
        await db.execute('CREATE INDEX photos_hash ON photos(hash)');
        await db.execute(
          'CREATE INDEX photos_state ON photos(state, retry_at)',
        );
        await db.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE lease (id INTEGER PRIMARY KEY, owner TEXT, until_ms INTEGER)',
        );
      },
    );
    return Store(db);
  }

  Future<T> get<T>(String key, T fallback) async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty
        ? fallback
        : jsonDecode(rows.first['value'] as String) as T;
  }

  Future<void> bindAccount(String publicKey) async {
    await db.transaction((txn) async {
      final rows = await txn.query('settings', where: 'key = ?', whereArgs: ['account-public-key']);
      final owner = rows.isEmpty ? '' : jsonDecode(rows.first['value'] as String) as String;
      if (owner.isNotEmpty && owner != publicKey) {
        throw StateError('Use the original recovery phrase and Sia account for this local library.');
      }
      if (owner.isEmpty) {
        await txn.insert('settings', {'key': 'account-public-key', 'value': jsonEncode(publicKey)});
      }
    });
  }

  Future<void> set(String key, Object value) => db
      .insert('settings', {
        'key': key,
        'value': jsonEncode(value),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  Future<void> enqueue(PhotoEntry photo) async {
    await db.insert(
      'photos',
      photo.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await db.update(
      'photos',
      {'state': 'pending', 'error': null, 'object_id': null, 'retry_at': 0},
      where: "key = ? AND state = 'missing'",
      whereArgs: [photo.key],
    );
  }

  Future<void> update(String key, Map<String, Object?> values) => db
      .update('photos', values, where: 'key = ?', whereArgs: [key])
      .then((_) {});

  Future<List<PhotoEntry>> photos({int limit = 1000}) async => (await db.query(
    'photos',
    orderBy: 'taken DESC',
    limit: limit,
  )).map(PhotoEntry.fromMap).toList();

  Future<List<PhotoEntry>> pending() async => (await db.query(
    'photos',
    where:
        "state IN ('pending', 'failed', 'uploading', 'pinned') AND retry_at <= ?",
    whereArgs: [DateTime.now().millisecondsSinceEpoch],
    orderBy: 'taken ASC',
    limit: 16,
  )).map(PhotoEntry.fromMap).toList();

  Future<String?> verifiedObject(String hash) async {
    final rows = await db.query(
      'photos',
      columns: ['object_id'],
      where: "hash = ? AND state = 'verified' AND object_id IS NOT NULL",
      whereArgs: [hash],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['object_id'] as String;
  }

  Future<void> fail(PhotoEntry photo, String message) async {
    final count = photo.attempts + 1;
    await update(photo.key, {
      'state': 'failed',
      'error': message,
      'attempts': count,
      'retry_at': DateTime.now().add(retryDelay(count)).millisecondsSinceEpoch,
    });
  }

  Future<void> retryNow() => db
      .rawUpdate(
        "UPDATE photos SET retry_at = 0 WHERE state = 'failed' OR state = 'pinned'",
      )
      .then((_) {});

  Future<Map<String, int>> counts() async => {
    for (final row in await db.rawQuery(
      'SELECT state, COUNT(*) AS n FROM photos GROUP BY state',
    ))
      row['state'] as String: row['n'] as int,
  };

  /// Background workers and the visible app share one durable upload lease.
  Future<String?> acquireLease() => db.transaction((txn) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await txn.query('lease', where: 'id = 1');
    if (existing.isNotEmpty && (existing.first['until_ms'] as int) > now) {
      return null;
    }
    final owner = '$now-${Random.secure().nextInt(1 << 32)}';
    await txn.insert('lease', {
      'id': 1,
      'owner': owner,
      'until_ms': now + 180000,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return owner;
  });

  Future<void> renewLease(String owner) => db
      .update(
        'lease',
        {'until_ms': DateTime.now().millisecondsSinceEpoch + 180000},
        where: 'id = 1 AND owner = ?',
        whereArgs: [owner],
      )
      .then((_) {});

  Future<void> releaseLease(String owner) => db
      .delete('lease', where: 'id = 1 AND owner = ?', whereArgs: [owner])
      .then((_) {});
}
