// General churning flow:
//
// With a synced wallet,
// 1. Create but do not broadcast a transaction spending one output/key image.
// 2. Get the block height associated with one of the decoy inputs.
// 3. Broadcast tx when the decoy input is as old or older than the real input.
// 4. Repeat.

import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:cs_monero/cs_monero.dart';
import 'package:cs_monero/src/ffi_bindings/monero_bindings_base.dart';
import 'package:monero_rpc/monero_rpc.dart';

const String version = "0.0.1";

ArgParser buildCreateParser() {
  return ArgParser()
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

ArgParser buildLoadParser() {
  return ArgParser()
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
  print("Usage: dart churner.dart <command> <flags> [arguments]");
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

Future<void> main(List<String> args) async {
  final mainParser = ArgParser(allowTrailingOptions: false)
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
    ..addCommand(
      "load",
      buildLoadParser(),
    )
    ..addCommand(
      "new",
      buildCreateParser(),
    );
  bool verbose = false;
  try {
    final parsedArgs = mainParser.parse(args);
    // Process the parsed arguments.
    if (parsedArgs.wasParsed("help")) {
      print(mainParser.usage);
      print("");
      print("Command-specific usage:");
      print("\nload:\n${buildLoadParser().usage}");
      print("\nnew:\n${buildCreateParser().usage}");
      return;
    }
    if (parsedArgs.wasParsed("version")) {
      print("churner version: $version");
      return;
    }
    if (parsedArgs.wasParsed("verbose")) {
      verbose = true;
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

    final MoneroWallet wallet;

    switch (parsedArgs.command?.name) {
      case "load":
        wallet = await _load(parsedArgs.command!);
        break;

      case "new":
        wallet = await _new(parsedArgs.command!);
        break;

      default:
        print("Unknown command: ${parsedArgs.command?.name}");
        print(mainParser.usage);
        return;
    }

    final nodeConfig = NodeConfig(
      uri: parsedArgs.command!["node"],
      user: parsedArgs.command!["node-user"],
      pass: parsedArgs.command!["node-pass"],
      ssl: parsedArgs.command!["ssl"],
      trusted: parsedArgs.command!["trusted"],
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

    wallet.startAutoSaving();

    // Wait for syncing to complete.
    while (!(await wallet.isSynced())) {
      if (verbose) {
        print("Wallet syncing...");
      }
      await Future.delayed(const Duration(seconds: 5));
    }
    print("Wallet synced.");

    while (true) {
      try {
        await churnOnce(
          wallet: wallet,
          daemonAddress: nodeConfig.uri,
          daemonUsername: nodeConfig.user,
          daemonPassword: nodeConfig.pass,
          verbose: verbose,
        );
      } catch (e, s) {
        print("Error while churning: $e\n$s");
      }
    }
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    print(e.message);
    print("");
    printUsage(mainParser);
  } catch (e, st) {
    print("Error occurred: $e");
    print(st);
  }
}

Future<MoneroWallet> _load(ArgResults args) async {
  // Extract arguments
  final walletConfig = WalletConfig(
    path: args["wallet"],
    pass: args["wallet-pass"],
  );

  final network = int.parse(args["network"]);

  // if (verbose) {
  //   print("[VERBOSE] Configuration:");
  //   for (final opt in results.options) {
  //     print("   $opt: ${results[opt]}");
  //   }
  // }
  //
  // if (verbose) {
  //   print("Positional arguments: ${results.rest}");
  //   print("[VERBOSE] All arguments: ${results.arguments}");
  // }

  final walletExists = MoneroWallet.isWalletExist(walletConfig.path);
  if (!walletExists) {
    throw Exception("Wallet not found");
  }

  final wallet = MoneroWallet.loadWallet(
    path: walletConfig.path,
    password: walletConfig.pass,
    networkType: network,
  );
  print("Wallet Loaded");

  return wallet;
}

Future<MoneroWallet> _new(ArgResults args) async {
  // Extract arguments
  final walletConfig = WalletConfig(
    path: args["wallet"],
    pass: args["wallet-pass"],
  );

  final network = int.parse(args["network"]);

  // if (verbose) {
  //   print("[VERBOSE] Configuration:");
  //   for (final opt in results.options) {
  //     print("   $opt: ${results[opt]}");
  //   }
  // }

  // if (verbose) {
  //   print("Positional arguments: ${results.rest}");
  //   print("[VERBOSE] All arguments: ${results.arguments}");
  // }

  final walletExists = MoneroWallet.isWalletExist(walletConfig.path);
  if (walletExists) {
    throw Exception("Wallet already exists");
  }

  // Create the wallet.
  final MoneroWallet wallet;
  try {
    wallet = await MoneroWallet.create(
        path: walletConfig.path,
        password: walletConfig.pass,
        seedType: MoneroSeedType.sixteen,
        networkType: network);
  } catch (e, s) {
    throw Exception("Error creating wallet: $e\n$s");
  }
  print("Wallet created successfully.");

  // Show the seed to the user for backup.
  final seed = wallet.getSeed();
  print("The wallet seed needs to be backed up!  Press ENTER to view it.");
  stdin.readLineSync();
  print("Wallet seed: $seed");
  print(
    "Press ENTER to continue.  The screen will be cleared in order to hide the seed for privacy.",
  );
  stdin.readLineSync();
  // Clear the console.
  print("\x1B[2J\x1B[0;0H");

  return wallet;
}

/// Performs one cycle of the churning process:
/// 1. Select an output to churn.
/// 2. Create a transaction (not broadcasted).
/// 3. Deserialize and inspect inputs via key offsets.
/// 4. Use RPC to retrieve output info and remove the real input from the list.
/// 5. Check churn conditions and broadcast when appropriate..
Future<void> churnOnce({
  required MoneroWallet wallet,
  required String daemonAddress,
  String? daemonUsername,
  String? daemonPassword,
  bool verbose = false,
  bool waitToCommit = true,
}) async {
  final myOutputs = await wallet.getOutputs(
    includeSpent: false,
    refresh: true,
  );
  if (myOutputs.isEmpty) {
    print(
        "No unspent outputs available.  Please send funds to this address:\n");
    print(wallet
        .getAddress()
        .value); // TODO: If account is made configurable elsewhere we should respect that here, too.

    // Delay for a bit before checking again.
    await Future.delayed(const Duration(seconds: 30));
  }

  // rng
  final random = Random.secure();

  // Pick an output at random for churning.
  //
  // In the future we could select a specific output based on some criteria.
  myOutputs.shuffle(random);
  final outputToChurn = myOutputs.first;
  if (verbose) {
    print("Using output with hash: ${outputToChurn.hash}, "
        "height: ${outputToChurn.height}, amount: ${outputToChurn.value}");
  }

  final accountIndex = 0; // Could be configurable.
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
    throw Exception("No outputs returned from get_outs call.");
  }

  // Remove our real input from the list, leaving just decoy inputs.
  final originalLength = getOutsResult.outs.length;
  getOutsResult.outs.removeWhere(
    (o) => o.txid == outputToChurn.hash && o.height == outputToChurn.height,
  );
  final removedCount = originalLength - getOutsResult.outs.length;
  if (verbose) {
    if (removedCount == 1) {
      print("Identified our real output among the decoys and removed it.");
    } else if (removedCount > 1) {
      throw Exception("Removed more than one output from the decoys.");
    } else {
      throw Exception("Our real output was not found among the decoys.");
    }
  }

  // Select a random decoy.
  getOutsResult.outs.shuffle(random);
  final randomDecoy = getOutsResult.outs.first;
  if (verbose) {
    print("Random decoy output height: ${randomDecoy.height}");
    print("Random decoy output TxID: ${randomDecoy.txid}");
  }

  // Check conditions and possibly wait before committing.
  await checkChurnConditionsAndWaitIfNeeded(
    wallet: wallet,
    daemonRpc: daemonRpc,
    outputToChurn: outputToChurn,
    decoyHeight: randomDecoy.height,
    pending: pending,
    waitToCommit: waitToCommit,
    verbose: verbose,
  );
}

/// Check churn conditions as per the specification:
///
/// If Age(Y) > Age(X), X is churnable: broadcast the transaction immediately.
///
/// If Age(Y) <= Age(X), X is not churnable:
///   - If `waitToCommit` is true: do not broadcast nor wait, just discard.
///   - Otherwise (if `waitToCommit` is false): wait until Age(X) reaches the
///     previously observed Age(Y) before broadcasting.
///
/// This function queries the current height to calculate Age(X) and Age(Y).
Future<void> checkChurnConditionsAndWaitIfNeeded({
  required MoneroWallet wallet,
  required DaemonRpc daemonRpc,
  required Output outputToChurn,
  required int decoyHeight,
  required PendingTransaction pending,
  required bool waitToCommit,
  bool verbose = false,
}) async {
  final currentHeight = await getCurrentHeight(daemonRpc);
  final ageX = currentHeight - outputToChurn.height;
  final ageY = currentHeight - decoyHeight;

  if (verbose) {
    print("Age(X): $ageX, Age(Y): $ageY");
  }

  if (ageY > ageX) {
    // X is churnable, broadcast immediately.
    if (verbose) {
      print("X is churnable.  Broadcasting transaction immediately.");
    }
    await wallet.commitTx(pending);
    print("Transaction broadcasted.");
  } else {
    // X is not churnable.
    if (waitToCommit) {
      // If waitToCommit is true, we discard the transaction now (no waiting, no broadcasting).
      if (verbose) {
        print(
            "X is not churnable and waitToCommit is true.  Discarding transaction.");
      }
      return; // Do not broadcast or wait.
    } else {
      // If waitToCommit is false, wait until Age(X) matches the observed Age(Y).
      if (verbose) {
        print(
            "X is not churnable.  Waiting until Age(X) reaches previously observed Age(Y)=$ageY before broadcasting.");
      }

      final targetAgeY = ageY;
      while (true) {
        final newHeight = await getCurrentHeight(daemonRpc);
        final newAgeX = newHeight - outputToChurn.height;
        if (verbose) {
          print(
              "Current block height: $newHeight. Age(X): $newAgeX, waiting for Age(X) >= $targetAgeY");
        }
        if (newAgeX >= targetAgeY) {
          break; // Conditions met: broadcast.
        }
        await Future.delayed(const Duration(seconds: 10));
      }

      if (verbose) {
        print(
            "Conditions met (Age(X) caught up to Age(Y)). Broadcasting transaction...");
      }
      await wallet.commitTx(pending);
      print("Transaction broadcasted.");
    }
  }
}

/// Query the daemon for the current blockchain height.
Future<int> getCurrentHeight(DaemonRpc daemonRpc) async {
  final info = await daemonRpc.postToEndpoint("/get_info", {});
  if (!info.containsKey("height")) {
    throw Exception("Height not found in get_info response.");
  }
  return info["height"];
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

/// Converts a list of relative key offsets to a list of absolute offsets.
List<int> convertRelativeToAbsolute(List<int> relativeOffsets) {
  List<int> absoluteOffsets = [];
  int sum = 0;
  for (final offset in relativeOffsets) {
    sum += offset;
    absoluteOffsets.add(sum);
  }
  return absoluteOffsets;
}
