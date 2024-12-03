import 'dart:convert';

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
          CREATE TABLE IF NOT EXISTS key_images (
            key_image TEXT PRIMARY KEY,
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
      'INSERT OR REPLACE INTO key_images (key_image, block_height) VALUES (?, ?)',
      [outputPublicKey, blockHeight],
    );
  }

  /// Retrieves the block height associated with a given output public key.
  Future<int?> getBlockHeightByOutputPublicKey(String outputPublicKey) async {
    final result = await _db.getOptional(
      'SELECT block_height FROM key_images WHERE key_image = ?',
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

        for (var txData in allTransactions) {
          final vout = txData['vout'] as List<dynamic>;

          for (var output in vout) {
            final target = output['target'] as Map<String, dynamic>;

            if (target.containsKey('key')) {
              final keyImage = target['key'] as String;
              await insertOutputPublicKey(keyImage, height);
              print('Inserted key image $keyImage at height $height');
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
        // Delete all data from the key_images table.
        await _db.execute('DELETE FROM key_images');
      } else {
        // Delete data from the key_images table from the RingCT activation height onward.
        await _db.execute(
          'DELETE FROM key_images WHERE block_height >= ?',
          [ringCtActivationHeight],
        );
      }

      // Reset the synced height in the sync_state table.
      await _db.execute('UPDATE sync_state SET synced_height = ? WHERE id = 1',
          [ringCtActivationHeight]);

      print('Rescan initiated.');
    } catch (e) {
      print('Error during rescan: $e');
    }
  }

  /// Closes the database connection.
  Future<void> close() async {
    await _db.close();
  }
}

void main() async {
  final db = KeyImageDatabase(
    dbPath: 'key_images.db',
    daemonUrl:
        'http://localhost:18081/json_rpc', // Replace with your Monero daemon URL.
    daemonUsername: 'user', // Replace with your username.
    daemonPassword: 'password', // Replace with your password.
  );

  await db.init();

  // To perform a rescan, uncomment one of the following lines:

  // Full rescan (delete all data and start over):
  // await db.rescan();

  // Partial rescan (overwrite data from RingCT activation height onward):
  // await db.rescan(fullRescan: false);

  await db.refresh();

  // Now you can query the database for output public keys.
  //
  // Get the height of a random key image in the database as an example:
  // ```
  // final height = await db.getBlockHeightByOutputPublicKey(
  //     '240d8b9b00222b81e51b9fda7571f17d672f7ee3bd5ad94d3dfdc81fe04bc98d');
  // print("Height: $height");
  // ``
  //
  // Proceed to churn.

  await db.close();
}
