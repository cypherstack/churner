// General churning flow:
//
// With a synced wallet,
// 1. Create but do not broadcast a transaction spending one output/key image.
// 2. Get the block height associated with one of the decoy inputs.
// 3. Broadcast tx when the decoy input is as old or older than the real input.
// 4. Repeat.

import 'dart:io';

import 'package:args/args.dart';
import 'package:cs_monero/cs_monero.dart';
import 'package:cs_monero/src/ffi_bindings/monero_bindings_base.dart';
import 'package:monero_rpc/monero_rpc.dart';

const String version = "0.0.1";

ArgParser buildParser() {
  return ArgParser()
    ..addFlag(
      "help",
      abbr: "h",
      negatable: false,
      help: "Print this usage information.",
    )
    ..addFlag(
      "verbose",
      abbr: "v",
      negatable: false,
      help: "Show additional command output.",
    )
    ..addFlag(
      "version",
      negatable: false,
      help: "Print the tool version.",
    )
    ..addOption(
      "wallet",
      abbr: "w",
      help: "Path to the Monero wallet file.",
      mandatory: true,
    )
    ..addOption(
      "wallet-pass",
      abbr: "p",
      help: "Password for the Monero wallet file.",
      mandatory: true,
    )
    ..addOption(
      "node",
      abbr: "u",
      help: "The Monero node URL to connect to.",
      mandatory: true,
    )
    ..addOption(
      "node-user",
      help: "Optional username for daemon digest authentication.",
      defaultsTo: null,
    )
    ..addOption(
      "node-pass",
      help: "Optional password for daemon digest authentication.",
      defaultsTo: null,
    )
    ..addOption(
      "network",
      abbr: "n",
      help: "Monero network",
      allowed: ["0", "1", "2"],
      allowedHelp: {"0": "mainnet", "1": "testnet", "2": "stagenet"},
      defaultsTo: "0",
    )
    ..addFlag(
      "ssl",
      help: "Use SSL when connecting to the node.",
      defaultsTo: true,
    )
    ..addFlag(
      "trusted",
      help: "Whether the node is considered trusted.",
      defaultsTo: true,
    );
}

void printUsage(ArgParser argParser) {
  print("Usage: dart churner.dart <flags> [arguments]");
  print(argParser.usage);
}

class WalletConfig {
  final String path, pass;

  WalletConfig({
    required this.path,
    required this.pass,
  });
}

class NodeConfig {
  final String uri;
  final String? user, pass;
  final bool ssl, trusted;

  NodeConfig({
    required this.uri,
    required this.user,
    required this.pass,
    required this.ssl,
    required this.trusted,
  });
}

Future<void> main(List<String> arguments) async {
  final ArgParser argParser = buildParser();
  bool verbose = false;
  try {
    final ArgResults results = argParser.parse(arguments);

    // Process the parsed arguments.
    if (results.wasParsed("help")) {
      printUsage(argParser);
      return;
    }
    if (results.wasParsed("version")) {
      print("churner version: $version");
      return;
    }
    if (results.wasParsed("verbose")) {
      verbose = true;
    }

    // Extract arguments
    final walletConfig = WalletConfig(
      path: results["wallet"],
      pass: results["wallet-pass"],
    );
    final nodeConfig = NodeConfig(
      uri: results["node"],
      user: results["node-user"],
      pass: results["node-pass"],
      ssl: results["ssl"],
      trusted: results["trusted"],
    );

    final network = int.parse(results["network"]);

    if (verbose) {
      print("[VERBOSE] Configuration:");
      for (final opt in results.options) {
        print("   $opt: ${results[opt]}");
      }
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

    if (verbose) {
      print("Positional arguments: ${results.rest}");
      print("[VERBOSE] All arguments: ${results.arguments}");
    }

    final walletExists = MoneroWallet.isWalletExist(walletConfig.path);
    if (!walletExists) {
      throw Exception("Wallet not found: $walletConfig.path");
    }

    final wallet = MoneroWallet.loadWallet(
      path: walletConfig.path,
      password: walletConfig.pass,
      networkType: network,
    );

    wallet.connect(
      daemonAddress: nodeConfig.uri,
      trusted: nodeConfig.trusted,
      daemonUsername: nodeConfig.user,
      daemonPassword: nodeConfig.pass,
      useSSL: nodeConfig.ssl,
      socksProxyAddress: null, // needed?
    );

    final connected = await wallet.isConnectedToDaemon();
    if (!connected) {
      throw Exception("Failed to connect to daemon: ${nodeConfig.uri}");
    }

    wallet.startSyncing();

    // TODO add listeners??
    wallet.startListeners();

    wallet.startAutoSaving();

    // Wait for syncing to complete.
    while (!(await wallet.isSynced())) {
      if (verbose) {
        print("Wallet syncing...");
      }
      await Future.delayed(const Duration(seconds: 5));
    }
    print("Wallet synced.");

    // TODO: Loop this.
    print("Churning once.");
    await churnOnce(
      wallet: wallet,
      daemonAddress: nodeConfig.uri,
      daemonUsername: nodeConfig.user,
      daemonPassword: nodeConfig.pass,
      verbose: verbose,
    );
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    print(e.message);
    print("");
    printUsage(buildParser());
  } catch (e, st) {
    print("Error occurred: $e");
    if (verbose) {
      print(st);
    }
  }
}

/// Performs one cycle of the churning process:
/// 1. Select an output to churn.
/// 2. Create a transaction (not broadcasted).
/// 3. Deserialize and inspect decoy offsets.
/// 4. Use daemon RPC to retrieve out info and remove the real output from the list.
/// 5. If conditions are met, commit (broadcast) the transaction.
Future<void> churnOnce({
  required MoneroWallet wallet,
  required String daemonAddress,
  String? daemonUsername,
  String? daemonPassword,
  bool verbose = false,
}) async {
  final myOutputs = await wallet.getOutputs(
    includeSpent: false,
    refresh: true,
  );

  if (myOutputs.isEmpty) {
    throw Exception("No unspent outputs available.");
  }

  // Pick an output at random for churning.
  myOutputs.shuffle();
  final outputToChurn = myOutputs.first;
  if (verbose) {
    print("Using output with hash: ${outputToChurn.hash}, "
        "height: ${outputToChurn.height}, amount: ${outputToChurn.value}");
  }

  final accountIndex = 0; // Could be configurable
  final pending = await wallet.createTx(
    output: Recipient(
      address: wallet
          .getAddress(
            accountIndex: accountIndex,
          )
          .value,
      amount: outputToChurn.value,
    ),
    priority: TransactionPriority.normal,
    accountIndex: accountIndex,
    preferredInputs: [outputToChurn],
    sweep: true,
  );
  final deserializedTx = DeserializedTransaction.deserialize(pending.hex);

  // Extract key offsets.
  List<int>? relativeOffsets;
  for (var input in deserializedTx.vin) {
    if (input is TxinToKey) {
      if (verbose) {
        print("Key Image: ${_bytesToHex(input.keyImage)}");
        print("Key Offsets: ${input.keyOffsets}");
      }
      relativeOffsets = input.keyOffsets.map((e) => e.toInt()).toList();
      break; // Select first input for demonstration purposes.
      // TODO: determine if the above is unacceptable.
    }
  }
  if (relativeOffsets == null || relativeOffsets.isEmpty) {
    throw Exception("No key offsets found in transaction inputs.");
  }

  final daemonRpc = DaemonRpc(
    "$daemonAddress/json_rpc",
    username: daemonUsername ?? "",
    password: daemonPassword ?? "",
  );
  final getOutsResult =
      await daemonRpc.getOuts(convertRelativeToAbsolute(relativeOffsets));
  if (getOutsResult.outs.isEmpty) {
    throw Exception("No outs returned from get_outs call.");
  }

  // Identify and remove our real output from the complete list of inputs,
  // leaving just decoy inputs.
  final originalLength = getOutsResult.outs.length;
  getOutsResult.outs.removeWhere(
    (o) => o.txid == outputToChurn.hash && o.height == outputToChurn.height,
  );
  final removedCount = originalLength - getOutsResult.outs.length;
  if (verbose) {
    if (removedCount > 0) {
      print("Identified our real output among the decoys and removed it.");
    } else {
      throw Exception("Our real output was not found among the decoys.");
    }
  }

  // Select a random decoy.
  getOutsResult.outs.shuffle();
  final randomDecoy = getOutsResult.outs.first;
  if (verbose) {
    print("Random decoy output height: ${randomDecoy.height}");
    print("Random decoy output TxID: ${randomDecoy.txid}");
  }

  // Compare ages.
  if (randomDecoy.height >= outputToChurn.height) {
    print("Conditions met. Broadcasting transaction...");
    await wallet.commitTx(pending);
    print("Transaction broadcasted.");
  } else {
    print("Conditions not met. Not broadcasting this transaction.");
  }
}

String get _libName {
  if (Platform.isWindows) {
    return "monero_libwallet2_api_c.dll";
  } else if (Platform.isLinux) {
    return "monero_libwallet2_api_c.so";
  } else {
    throw UnsupportedError(
      "Platform \"${Platform.operatingSystem}\" is not supported",
    );
  }
}

String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
}
