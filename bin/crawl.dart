import 'dart:convert';
import 'dart:io'; // Used for db migration.

import 'package:monero_rpc/monero_rpc.dart';
import 'package:sqlite_async/sqlite_async.dart';

class KeyImageDatabase {
  final String dbPath;
  final String daemonUrl;
  final String daemonUsername;
  final String daemonPassword;

  late final SqliteDatabase _db;
  late final DaemonRpc _daemonRpc;

  static const int ringCtActivationHeight = 1220516;

  KeyImageDatabase({
    required this.dbPath,
    required this.daemonUrl,
    required this.daemonUsername, // TODO: Make optional (upgrade monero_rpc).
    required this.daemonPassword,
  });

  /// Initializes the database and the Monero daemon RPC client.
  Future<void> init() async {
    final migrations = SqliteMigrations()
      ..add(SqliteMigration(1, (tx) async {
        await tx.execute('''
          CREATE TABLE IF NOT EXISTS pub_keys (
            pub_key TEXT PRIMARY KEY,
            block_height INTEGER
          )
        ''');

        await tx.execute('''
          CREATE TABLE IF NOT EXISTS sync_state (
            id INTEGER PRIMARY KEY,
            synced_height INTEGER
          )
        ''');
      }));

    _db = SqliteDatabase(path: dbPath);
    await migrations.migrate(_db);

    await _initializeSyncState();

    _daemonRpc = DaemonRpc(
      daemonUrl,
      username: daemonUsername,
      password: daemonPassword,
    );
  }

  Future<void> _initializeSyncState() async {
    final result = await _db
        .getOptional('SELECT synced_height FROM sync_state WHERE id = 1');
    if (result == null) {
      // Insert an initial sync height of RingCT activation height.
      await _db.execute(
          'INSERT INTO sync_state (id, synced_height) VALUES (1, ?)',
          [ringCtActivationHeight]);
    }
  }

  /// Retrieves the last synced block height from the database.
  Future<int> getSyncedHeight() async {
    final result =
        await _db.get('SELECT synced_height FROM sync_state WHERE id = 1');
    return result['synced_height'] as int;
  }

  /// Updates the synced block height in the database.
  Future<void> updateSyncedHeight(int height) async {
    await _db.execute(
        'UPDATE sync_state SET synced_height = ? WHERE id = 1', [height]);
  }

  /// Inserts a key image and its corresponding block height into the database.
  Future<void> insertOutputPublicKey(
      String outputPublicKey, int blockHeight) async {
    await _db.execute(
      'INSERT OR REPLACE INTO pub_keys (pub_key, block_height) VALUES (?, ?)',
      [outputPublicKey, blockHeight],
    );
  }

  /// Retrieves the block height associated with a given output public key.
  Future<int?> getBlockHeightByOutputPublicKey(String outputPublicKey) async {
    final result = await _db.getOptional(
      'SELECT block_height FROM pub_keys WHERE pub_key = ?',
      [outputPublicKey],
    );
    return result?['block_height'] as int?;
  }

  /// Synchronizes the database with the Monero blockchain.
  Future<void> refresh() async {
    final cachedHeight = await getSyncedHeight();

    final stopwatch = Stopwatch()..start();
    // TODO: Remove.

    // Get the current blockchain height from the daemon.
    Map<String, dynamic> result;
    try {
      result = await _daemonRpc.call('get_info', {});
    } catch (e) {
      print('Error getting blockchain info: $e');
      stopwatch.stop();
      print('Total time elapsed: ${stopwatch.elapsed}');
      return;
    }

    final currentHeight = result['height'] as int;

    if (cachedHeight >= currentHeight) {
      print('Database is already synced to height $currentHeight.');
      stopwatch.stop();
      print('Total time elapsed: ${stopwatch.elapsed}');
      return;
    }

    print(
        'Syncing blocks from height ${cachedHeight + 1} to $currentHeight...');

    int lastSyncedHeight = cachedHeight;

    for (int height = cachedHeight + 1; height <= currentHeight; height++) {
      print('Processing block at height $height');
      try {
        final blockResult = await _daemonRpc.call('get_block', {
          'height': height,
          'decode_as_json': true,
        });

        final blockJson = blockResult['json'] as String;
        final blockData = jsonDecode(blockJson);

        // Process all transactions for any `key`s.

        List<Map<String, dynamic>> allTransactions = [];
        final minerTx = blockData['miner_tx'] as Map<String, dynamic>;
        allTransactions.add(minerTx);

        final txHashes =
            (blockData['tx_hashes'] as List<dynamic>).cast<String>();
        if (txHashes.isNotEmpty) {
          final txsResult =
              await _daemonRpc.postToEndpoint('/get_transactions', {
            'txs_hashes': txHashes,
            'decode_as_json': true,
          });

          final txs = txsResult['txs'] as List<dynamic>;

          for (var tx in txs) {
            final txJson = tx['as_json'] as String;
            final txData = jsonDecode(txJson) as Map<String, dynamic>;

            allTransactions.add(txData);
          }
        }

        // Process all transactions for any `key`s.
        for (var txData in allTransactions) {
          final vout = txData['vout'] as List<dynamic>;

          for (var output in vout) {
            final target = output['target'] as Map<String, dynamic>;

            String? pubKey;

            if (target.containsKey('key')) {
              pubKey = target['key'] as String;
            } else if (target.containsKey('tagged_key')) {
              final taggedKey = target['tagged_key'] as Map<String, dynamic>;
              pubKey = taggedKey['key'] as String;
            }

            if (pubKey != null) {
              await insertOutputPublicKey(pubKey, height);
              print('Inserted pub key $pubKey at height $height');
            }
          }
        }

        await updateSyncedHeight(height);
        lastSyncedHeight = height;
      } catch (e, s) {
        print('Error processing block at height $height: $e');
        print(s);
        continue;
      }

      // Uncomment for the example in main() below to run quicker (in 2s or so).
      // if (height > 1220591) {
      //   stopwatch.stop();
      //   print('Sync completed up to height $lastSyncedHeight.');
      //   print('Total time elapsed: ${stopwatch.elapsed}');
      //   return;
      // }
    }

    stopwatch.stop();
    print('Sync completed up to height $lastSyncedHeight.');
    print('Total time elapsed: ${stopwatch.elapsed}');
  }

  /// Rescans the blockchain starting from the RingCT activation height.
  /// If [fullRescan] is true (default), deletes all data and starts over.
  /// If [fullRescan] is false, keeps existing data and overwrites from the specified height onward.
  Future<void> rescan({bool fullRescan = true}) async {
    print('Rescanning the blockchain from RingCT activation height...');
    try {
      if (fullRescan) {
        // Delete all data from the pub_keys table.
        await _db.execute('DELETE FROM pub_keys');
      }

      // Reset the synced height in the sync_state table.
      await _db.execute('UPDATE sync_state SET synced_height = ? WHERE id = 1',
          [ringCtActivationHeight]);

      print('Rescan initiated.');
    } catch (e) {
      print('Error during rescan: $e');
    }
  }

  /// Repairs the database by finding the highest recorded block and continues
  /// the synchronization process from that point.
  Future<void> repair() async {
    print('Starting repair process...');
    try {
      // Find the highest block height from the pub_keys table.
      final result = await _db
          .getOptional('SELECT MAX(block_height) as max_height FROM pub_keys');
      int highestBlock = ringCtActivationHeight;

      if (result != null && result['max_height'] != null) {
        highestBlock = result['max_height'] as int;
        print('Highest recorded block height is $highestBlock.');
      } else {
        print('No key images found. Starting from RingCT activation height.');
      }

      // Update the synced height in the sync_state table.
      await _db.execute('UPDATE sync_state SET synced_height = ? WHERE id = 1',
          [highestBlock]);

      // Continue synchronization from the highest block.
      await refresh();
    } catch (e) {
      print('Error during repair: $e');
    }
  }

  /// Closes the database connection.
  Future<void> close() async {
    await _db.close();
  }
}

/// Migrates old key_images.db to new (shiny) pub_keys.db.
///
/// This can be removed if you (dear reader) do not have a key_images.db.
Future<void> migrateKeyImagesToPubKeys({
  required String oldDbPath,
  required String newDbPath,
}) async {
  if (!File(oldDbPath).existsSync()) {
    throw Exception('Source database file $oldDbPath does not exist.');
  }

  // Open connections to the old and new databases.
  final oldDb = SqliteDatabase(path: oldDbPath);
  final newDb = SqliteDatabase(path: newDbPath);

  print('Migrating $oldDbPath to $newDbPath...');

  try {
    // Create the new database schema.
    final migrations = SqliteMigrations()
      ..add(SqliteMigration(1, (tx) async {
        await tx.execute('''
          CREATE TABLE IF NOT EXISTS pub_keys (
            pub_key TEXT PRIMARY KEY,
            block_height INTEGER
          )
        ''');

        await tx.execute('''
          CREATE TABLE IF NOT EXISTS sync_state (
            id INTEGER PRIMARY KEY,
            synced_height INTEGER
          )
        ''');
      }));

    print('Migration set up...');
    await migrations.migrate(newDb);

    print('Getting all keys...');
    // Migrate data from the old database to the new database.
    final oldKeyImages = await oldDb.getAll('SELECT * FROM key_images');

    print('Inserting keys...');
    for (final row in oldKeyImages) {
      final keyImage = row['key_image'] as String?;
      final blockHeight = row['block_height'] as int?;

      if (keyImage != null && blockHeight != null) {
        await newDb.execute(
          'INSERT INTO pub_keys (pub_key, block_height) VALUES (?, ?)',
          [keyImage, blockHeight],
        );
        print('Migrated $keyImage at height $blockHeight');
      }
    }

    // Migrate the sync state if it exists.
    final oldSyncState = await oldDb.getOptional(
      'SELECT synced_height FROM sync_state WHERE id = 1',
    );

    if (oldSyncState != null) {
      final syncedHeight = oldSyncState['synced_height'] as int;
      await newDb.execute(
        'INSERT INTO sync_state (id, synced_height) VALUES (1, ?)',
        [syncedHeight],
      );
    } else {
      // Set default sync height if no sync state exists.
      const defaultSyncHeight = 1220516; // RingCT activation height.
      await newDb.execute(
        'INSERT INTO sync_state (id, synced_height) VALUES (1, ?)',
        [defaultSyncHeight],
      );
    }

    print('Migration completed successfully.');
  } catch (e, s) {
    print('Error during migration: $e');
    print(s);
  } finally {
    // Close database connections.
    await oldDb.close();
    await newDb.close();
  }
}

void main() async {
  // If you have an old key_images.db, migrate it using:
  // try {
  //   await migrateKeyImagesToPubKeys(
  //     oldDbPath: 'key_images.db', // Path to the old database.
  //     newDbPath: 'pub_keys.db', // Path to the new database.
  //   );
  // } catch (e) {
  //   print('Migration failed: $e');
  // }

  final db = KeyImageDatabase(
    dbPath: 'pub_keys.db',
    daemonUrl:
        'http://localhost:18081/json_rpc', // Replace with your Monero daemon URL.
    daemonUsername: 'user', // Replace with your username.
    daemonPassword: 'password', // Replace with your password.
  );

  await db.init();

  // To perform a rescan, uncomment one of the following lines:
  // await db.rescan(); // Delete all data and start over.
  // await db.rescan(fullRescan: false); // Add to/overwrite data from RingCT activation height onward.

  // await db.repair(); // Restart from the highest-saved block height.

  await db.refresh();

  // Now you can query the database for output public keys.
  //
  // Get the height of a random key image in the database as an example:
  // ```
  // final height = await db.getBlockHeightByOutputPublicKey(
  //     '240d8b9b00222b81e51b9fda7571f17d672f7ee3bd5ad94d3dfdc81fe04bc98d');
  // print("Height: $height");
  // ```

  // Proceed to churn.

  await db.close();
}
