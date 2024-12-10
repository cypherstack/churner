// General churning flow:
//
// With a synced wallet,
// 1. Create but do not broadcast a transaction spending one output/key image.
// 2. Get the block height associated with one of the decoy inputs.
// 3. Broadcast tx when the decoy input is as old or older than the real input.
// 4. Repeat until churnRounds is reached (if specified).

import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:ascii_qr/ascii_qr.dart';
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
    )
    ..addOption(
      "rounds",
      abbr: "r",
      help: "The number of rounds of churn to perform.  0 for infinite.",
      defaultsTo: "0",
    );
}

void printUsage(ArgParser argParser) {
  l("Usage: dart churner.dart <flags> [arguments]");
  l(argParser.usage);
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

final accountIndex =
    0; // TODO: make configurable via cli arg and get rid of global variable here.

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
      l("churner version: $version");
      return;
    }
    if (results.wasParsed("verbose")) {
      verbose = true;
    }

    // Extract arguments
    final walletConfig = WalletConfig(
      path: results["wallet"] as String,
      pass: results["wallet-pass"] as String,
    );
    final nodeConfig = NodeConfig(
      uri: results["node"] as String,
      user: results["node-user"] as String?,
      pass: results["node-pass"] as String?,
      ssl: results["ssl"] as bool,
      trusted: results["trusted"] as bool,
    );

    final network = int.parse(results["network"] as String);
    final churnRounds = int.parse(results["rounds"] as String);

    if (verbose) {
      l("[VERBOSE] Configuration settings being applied:");
      l("   Wallet path: ${results["wallet"]}");
      l("   Node URL: ${results["node"]}");
      l("   Network type: ${results["network"]} (${{
        "0": "mainnet",
        "1": "testnet",
        "2": "stagenet",
      }[results["network"]]})");
      l("   Using SSL: ${results["ssl"]}");
      l("   Node trusted: ${results["trusted"]}");
      l("   Churn rounds: ${results["rounds"]} (0 = infinite)");
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
      l("Positional arguments: ${results.rest}");
      l("[VERBOSE] All arguments: ${results.arguments}");
    }

    final MoneroWallet wallet;
    final walletExists = MoneroWallet.isWalletExist(walletConfig.path);
    if (!walletExists) {
      l("Wallet not found: ${walletConfig.path}");

      // Prompt the user as to if they want to create a new wallet at the path.
      l("Would you like to create a new wallet at this path? (y/n)");
      final response = stdin.readLineSync();
      if (response?.toLowerCase() != "y") {
        l("Exiting.");
        return;
      }

      // Create the wallet.
      try {
        wallet = await MoneroWallet.create(
          path: walletConfig.path,
          password: walletConfig.pass,
          seedType: MoneroSeedType.sixteen,
          networkType: network,
        );
      } catch (e, s) {
        throw Exception("Error creating wallet: $e\n$s");
      }
      l("Wallet created successfully.");
    } else {
      wallet = MoneroWallet.loadWallet(
        path: walletConfig.path,
        password: walletConfig.pass,
        networkType: network,
      );
      l("Wallet Loaded");
    }

    if (!walletExists) {
      // Show the seed to the user for backup.
      final seed = wallet.getSeed();
      l("The wallet seed needs to be backed up!  Press ENTER to view it.");
      stdin.readLineSync();
      l("Wallet seed: $seed");
      l("Press ENTER to continue.  The screen will be cleared in order to hide the seed for privacy.");
      stdin.readLineSync();
      // Clear the console.
      l("\x1B[2J\x1B[0;0H");
    }

    l("Connecting to: \"${nodeConfig.uri}\" ...");

    await wallet.connect(
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

    l("Connected");

    wallet.startSyncing();

    wallet.startAutoSaving();

    // Wait for syncing to complete.
    while (!(await wallet.isSynced())) {
      if (verbose) {
        l("Wallet syncing...");
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    l("Wallet synced.");

    int churnCount = 0;
    // If churnRounds == 0, we churn indefinitely.
    while (churnRounds == 0 || churnCount < churnRounds) {
      try {
        final churned = await churnOnce(
          wallet: wallet,
          daemonAddress: nodeConfig.uri,
          daemonUsername: nodeConfig.user,
          daemonPassword: nodeConfig.pass,
          verbose: verbose,
        );
        if (churned) {
          churnCount++;
          if (verbose && churnRounds > 0) {
            l("Churned $churnCount/$churnRounds times.");
          }
        }
      } catch (e, s) {
        l("Error while churning: $e\n$s");
        // Add a small delay as a hackfix for the "No unlocked balance" (non-)issue.
        await Future<void>.delayed(const Duration(seconds: 60));
      }
    }

    l("Completed $churnCount churn round(s). Exiting.");
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    l(e.message);
    l("");
    printUsage(buildParser());
  } catch (e, st) {
    l("Error occurred: $e");
    l(st);
  }
}

/// Performs one cycle of the churning process:
/// 1. Select an output to churn.
/// 2. Create a transaction (not broadcasted).
/// 3. Deserialize and inspect inputs via key offsets.
/// 4. Use RPC to retrieve output info and remove the real input from the list.
/// 5. Check churn conditions and broadcast when appropriate.
///
/// Returns true if a churn was completed (i.e., a transaction was broadcasted).
/// Returns false if no churn was performed (e.g. no outputs available or the
/// transaction was discarded).
Future<bool> churnOnce({
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
    l("No unspent outputs available.  Please send funds to this address:\n");

    final String address = wallet.getAddress(accountIndex: accountIndex).value;
    l(address);
    l(AsciiQrGenerator.generate("monero:$address"));

    // Delay for a bit before checking again.
    await Future<void>.delayed(const Duration(seconds: 30));
    return false;
  }
  if (verbose) {
    l("Found ${myOutputs.length} unspent outputs.");
  }

  // rng
  final random = Random.secure();

  // Pick an output at random for churning.
  //
  // In the future we could select a specific output based on some criteria.
  myOutputs.shuffle(random);
  final outputToChurn = myOutputs.first;
  if (verbose) {
    l("Using output for churn operation:");
    l("   Transaction hash: ${outputToChurn.hash}");
    l("   Block height: ${outputToChurn.height}");
    l("   Amount: ${outputToChurn.value} atomic units");
  }

  l("Creating churn transaction...");
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
  if (verbose) {
    l("Transaction details:");
    l("   Transaction hash: ${pending.txid}");
    l("   Amount: ${pending.amount}");
    l("   Fee: ${pending.fee}");
  }
  final deserializedTx = DeserializedTransaction.deserialize(pending.hex);
  if (verbose) {
    l("Deserialized transaction:");
    l("   Version: ${deserializedTx.version}");
    l("   Unlock time: ${deserializedTx.unlockTime}");
    l("   Inputs: ${deserializedTx.vin.length}");
    l("   Outputs: ${deserializedTx.vout.length}");
  }

  // Extract key offsets.
  List<int>? relativeOffsets;
  for (final input in deserializedTx.vin) {
    if (input is TxinToKey) {
      if (verbose) {
        l("Key Image: ${_bytesToHex(input.keyImage)}");
        l("Key Offsets: ${input.keyOffsets}");
      }
      relativeOffsets = input.keyOffsets.map((e) => e.toInt()).toList();
      break; // Select first input for demonstration purposes.
      // TODO: determine if the above is unacceptable.
    }
  }
  if (relativeOffsets == null || relativeOffsets.isEmpty) {
    throw Exception("No key offsets found in transaction inputs.");
  }
  if (verbose) {
    l("Relative key offsets: $relativeOffsets");
    l("Absolute key offsets: ${convertRelativeToAbsolute(relativeOffsets)}");
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
  if (verbose) {
    l("get_outs result:");
    l("   Outputs: ${getOutsResult.outs.length}");
  }

  // Remove our real input from the list, leaving just decoy inputs.
  final originalLength = getOutsResult.outs.length;
  getOutsResult.outs.removeWhere(
    (o) => o.txid == outputToChurn.hash && o.height == outputToChurn.height,
  );
  final removedCount = originalLength - getOutsResult.outs.length;
  if (verbose) {
    if (removedCount == 1) {
      l("Identified our real output among the decoys and removed it.");
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
    l("Random decoy output height: ${randomDecoy.height}");
    l("Random decoy output TxID: ${randomDecoy.txid}");
  }

  // Check conditions and possibly wait before committing.
  final churnCompleted = await checkChurnConditionsAndWaitIfNeeded(
    wallet: wallet,
    daemonRpc: daemonRpc,
    outputToChurn: outputToChurn,
    decoyHeight: randomDecoy.height,
    pending: pending,
    waitToCommit: waitToCommit,
    verbose: verbose,
  );

  return churnCompleted;
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
/// Returns true if a transaction was broadcasted, false otherwise.
Future<bool> checkChurnConditionsAndWaitIfNeeded({
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
    l("\nAge analysis:");
    l("   Current block height: $currentHeight");
    l("   Real input (X) block height: ${outputToChurn.height}");
    l("   Decoy input (Y) block height: $decoyHeight");
    l("   Age of real input (X): $ageX blocks");
    l("   Age of decoy input (Y): $ageY blocks");
    l("\nPrivacy calculation:");
    if (ageY > ageX) {
      l("   Decoy is older than real input - good for privacy");
      l("   Proceeding with immediate broadcast");
    } else {
      l("   Real input is older than decoy - suboptimal for privacy");
      if (waitToCommit) {
        l("   Waiting for real input to age sufficiently");
        l("   Target age difference to overcome: ${ageX - ageY} blocks");
      } else {
        l("   Discarding transaction per waitToCommit setting");
      }
    }
  }

  if (ageY > ageX) {
    // X is churnable, broadcast immediately.
    if (verbose) {
      l("X is churnable.  Broadcasting transaction immediately.");
    }
    await wallet.commitTx(pending);
    l("Transaction broadcasted.");
    return true;
  } else {
    // X is not churnable.
    if (waitToCommit) {
      // If waitToCommit is true, discard the transaction now.
      if (verbose) {
        l("X is not churnable and waitToCommit is true.  Discarding transaction.");
      }
      return false;
    } else {
      // If waitToCommit is false, wait until Age(X) matches the observed Age(Y).
      if (verbose) {
        l("X is not churnable.  Waiting until Age(X) reaches previously observed Age(Y)=$ageY before broadcasting.");
      }

      final targetAgeY = ageY;
      while (true) {
        final newHeight = await getCurrentHeight(daemonRpc);
        final newAgeX = newHeight - outputToChurn.height;
        if (verbose) {
          l("Current block height: $newHeight. Age(X): $newAgeX, waiting for Age(X) >= $targetAgeY");
        }
        if (newAgeX >= targetAgeY) {
          break; // Conditions met: broadcast.
        }
        await Future<void>.delayed(const Duration(seconds: 10));
      }

      if (verbose) {
        l("Conditions met (Age(X) caught up to Age(Y)). Broadcasting transaction...");
      }
      await wallet.commitTx(pending);
      l("Transaction broadcasted.");
      return true;
    }
  }
}

/// Query the daemon for the current blockchain height.
Future<int> getCurrentHeight(DaemonRpc daemonRpc) async {
  final info = await daemonRpc.postToEndpoint("/get_info", {});
  if (!info.containsKey("height")) {
    throw Exception("Height not found in get_info response.");
  }
  return info["height"] as int;
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
  final List<int> absoluteOffsets = [];
  int sum = 0;
  for (final offset in relativeOffsets) {
    sum += offset;
    absoluteOffsets.add(sum);
  }
  return absoluteOffsets;
}

void l(Object? object) {
  // ignore: avoid_print
  print(object);
}
