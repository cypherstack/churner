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
    );
}

void printUsage(ArgParser argParser) {
  print('Usage: dart churner.dart <flags> [arguments]');
  print(argParser.usage);
}

void main(List<String> arguments) {
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

    // set path of .so lib
    final thisDirPath = Platform.pathSeparator +
        Platform.script.pathSegments
            .sublist(0, Platform.script.pathSegments.length - 1)
            .join(Platform.pathSeparator);

    // override here as cs_monero normally uses flutter to bundle the lib
    manuallyOverrideLibPath(
      thisDirPath + Platform.pathSeparator + _libName,
    );

    final walletExists = MoneroWallet.isWalletExist("lol");
    print("Wallet exists: $walletExists"); // should print out false fir "lol"

    // Act on the arguments provided.
    print('Positional arguments: ${results.rest}');
    if (verbose) {
      print('[VERBOSE] All arguments: ${results.arguments}');
    }
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    print(e.message);
    print('');
    printUsage(argParser);
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
