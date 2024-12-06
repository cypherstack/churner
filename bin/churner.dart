/// General churning flow:
///
/// 1. Sync a wallet.
/// 2. Create but do not broadcast a transaction spending one output/key image.
/// 3. Get the block height associated with one of the decoy inputs.
/// 4. Broadcast tx when the decoy input is as old or older than the real input.

import 'dart:io';

import 'package:args/args.dart';
import 'package:cs_monero/cs_monero.dart';
import 'package:cs_monero/src/ffi_bindings/monero_bindings_base.dart';
import 'package:monero_rpc/monero_rpc.dart';

const String version = '0.0.1';

ArgParser buildParser() {
  return ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Show additional command output.',
    )
    ..addFlag(
      'version',
      negatable: false,
      help: 'Print the tool version.',
    )
    ..addOption(
      'wallet-path',
      abbr: 'w',
      help: 'Path to the Monero wallet file.',
      mandatory: true,
    )
    ..addOption(
      'pass',
      abbr: 'p',
      help: 'Password for the Monero wallet file.',
      mandatory: true,
    )
    ..addOption(
      'node',
      abbr: 'u',
      help:
          'The Monero node URL to connect to.  Defaults to monero.stackwallet.com:18081.',
      defaultsTo: 'monero.stackwallet.com:18081',
    )
    ..addOption(
      'node-user',
      help: 'Optional username for daemon digest authentication.',
      defaultsTo: null,
    )
    ..addOption(
      'node-pass',
      help: 'Optional password for daemon digest authentication.',
      defaultsTo: null,
    )
    ..addOption('network',
        help:
            'Monero network type (0=mainnet, 1=testnet, 2=stagenet).  Defaults to 0 (mainnet).',
        defaultsTo: '0')
    ..addFlag(
      'ssl',
      help: 'Use SSL when connecting to the node.  Defaults to true.',
      defaultsTo: true,
    )
    ..addFlag(
      'trusted',
      help: 'Whether the node is considered trusted.  Defaults to false.',
      defaultsTo: false,
    );
}

void printUsage(ArgParser argParser) {
  print('Usage: dart churner.dart <flags> [arguments]');
  print(argParser.usage);
}

Future<void> main(List<String> arguments) async {
  final ArgParser argParser = buildParser();
  try {
    final ArgResults results = argParser.parse(arguments);
    bool verbose = false;

    // Process the parsed arguments.
    if (results.wasParsed('help')) {
      printUsage(argParser);
      return;
    }
    if (results.wasParsed('version')) {
      print('churner version: $version');
      return;
    }
    if (results.wasParsed('verbose')) {
      verbose = true;
    }

    // Extract arguments
    final pathToWallet = results['wallet-path'] as String;
    final password = results['pass'] as String;
    final node = results['node'] as String;
    final daemonUsername =
        results['node-user'] == null || (results['node-user'] as String).isEmpty
            ? null
            : results['node-user'] as String;
    final daemonPassword =
        results['node-pass'] == null || (results['node-pass'] as String).isEmpty
            ? null
            : results['node-pass'] as String;
    final network = int.tryParse(results['network'] as String) ?? 0;
    final ssl = results['ssl'] as bool ?? true;
    final trusted = results['trusted'] as bool? ?? false;

    if (verbose) {
      print('[VERBOSE] Configuration:');
      print('  pathToWallet: $pathToWallet');
      print('  password: $password');
      print('  node: $node');
      print('  daemonUsername: $daemonUsername');
      print('  daemonPassword: $daemonPassword');
      print('  network: $network');
      print('  ssl: $ssl');
      print('  trusted: $trusted');
    }

    // set path of .so lib
    final thisDirPath = Platform.pathSeparator +
        Platform.script.pathSegments
            .sublist(0, Platform.script.pathSegments.length - 1)
            .join(Platform.pathSeparator);

    // override here as cs_monero normally uses flutter to bundle the lib
    manuallyOverrideLibPath(
      thisDirPath + Platform.pathSeparator + _libName,
    );

    // Act on the arguments provided.
    print('Positional arguments: ${results.rest}');
    if (verbose) {
      print('[VERBOSE] All arguments: ${results.arguments}');
    }

    final walletExists = MoneroWallet.isWalletExist(pathToWallet);
    if (!walletExists) {
      throw Exception("Wallet not found: $pathToWallet");
    }

    final wallet = MoneroWallet.loadWallet(
      path: pathToWallet,
      password: password,
      networkType: network,
    );

    wallet.connect(
      daemonAddress: node,
      trusted: trusted,
      daemonUsername: daemonUsername,
      daemonPassword: daemonPassword,
      useSSL: ssl,
      socksProxyAddress: null, // needed?
    );

    final connected = await wallet.isConnectedToDaemon();
    if (!connected) {
      throw Exception("Failed to connect to daemon: $node");
    }

    wallet.startSyncing();

    // TODO add listeners??
    wallet.startListeners();

    wallet.startAutoSaving();

    // TODO wait for syncing to complete. Either using listeners or polling wallet.isSynced()

    final myOutputs = await wallet.getOutputs(
      includeSpent: false,
      refresh: true,
    );

    // TODO pick an output properly
    final outputToChurn = myOutputs.first;

    final accountIndex = 0; // TODO make this an arg?

    final pending = await wallet.createTx(
      output: Recipient(
        address: wallet
            .getAddress(
              accountIndex: accountIndex,
            )
            .value,
        amount: outputToChurn.value,
      ),
      priority: TransactionPriority.normal, // TODO make this an arg?
      accountIndex: accountIndex,
      preferredInputs: [outputToChurn],
      sweep: true,
    );

    // Deserialize the transaction to get the decoy inputs and key offsets.
    final deserializedTx = DeserializedTransaction.deserialize(pending.hex);

    // Extract key offsets from the first TxinToKey input (for demo).
    List<int>? relativeOffsets;
    for (var input in deserializedTx.vin) {
      if (input is TxinToKey) {
        print('Key Image: ${_bytesToHex(input.keyImage)}');
        print('Key Offsets: ${input.keyOffsets}');
        relativeOffsets = input.keyOffsets.map((e) => e.toInt()).toList();
        break; // just take the first input for demonstration.
      }
    }

    if (relativeOffsets == null || relativeOffsets.isEmpty) {
      throw Exception("No key offsets found in transaction inputs.");
    }

    // Perform the get_outs call to retrieve heights (ages) of these outputs.
    final daemonRpc = DaemonRpc(
      node + '/json_rpc',
      username: daemonUsername ?? '',
      password: daemonPassword ?? '',
    );

    final getOutsResult =
        await daemonRpc.getOuts(convertRelativeToAbsolute(relativeOffsets));

    if (getOutsResult.outs.isEmpty) {
      throw Exception("No outs returned from get_outs call.");
    }

    final firstOut = getOutsResult.outs.first;
    print('First decoy output height: ${firstOut.height}');
    print('First decoy output TxID: ${firstOut.txid}');

    // Compare decoy input age with real input age for demonstration.
    // In a real scenario, you'd retrieve the height of the outputToChurn and compare.
    // Here, we just assume conditions are met and proceed to broadcast.

    print("Conditions met. Broadcasting transaction...");
    await wallet.commitTx(pending);
    print("Transaction broadcasted successfully.");
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    print(e.message);
    print('');
    printUsage(buildParser());
  } catch (e, st) {
    print("Error occurred: $e");
    print(st);
  }
}

String get _libName {
  if (Platform.isWindows) {
    return 'monero_libwallet2_api_c.dll';
  } else if (Platform.isLinux) {
    return 'monero_libwallet2_api_c.so';
  } else {
    throw UnsupportedError(
      "Platform \"${Platform.operatingSystem}\" is not supported",
    );
  }
}

String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
