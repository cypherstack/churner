import 'dart:io';
import 'dart:math';

const kMoneroCRepo = "https://github.com/cypherstack/monero_c";
const kMoneroCHash = "daa37c3c4cf869909a8fcd93e5b0f7ad43455126";

final envProjectDir = File.fromUri(Platform.script).parent.parent.path;

String get envToolsDir => "$envProjectDir${Platform.pathSeparator}tools";
String get envBuildDir => "$envProjectDir${Platform.pathSeparator}build";
String get envMoneroCDir => "$envBuildDir${Platform.pathSeparator}monero_c";
String get envOutputsDir =>
    "$envBuildDir${Platform.pathSeparator}built_outputs";

void main(List<String> args) async {
  const platforms = [
    // "macos",
    "linux",
    "windows",
  ];
  const coins = [
    "monero",
    // "wownero",
  ];

  if (args.length != 1) {
    throw ArgumentError(
      "Missing platform argument. Expected one of $platforms",
    );
  }
  final platform = args.first;
  if (!platforms.contains(args.first)) {
    throw ArgumentError(args.first);
  }

  final moneroCDir = Directory(envMoneroCDir);
  if (!moneroCDir.existsSync()) {
    l("Did not find monero_c. Calling prepareMoneroC()...");
    await prepareMoneroC();
  }

  final thisDir = Directory.current;
  Directory.current = moneroCDir;

  final nProc = _getNProc(platform);
  final triples = _getTriples(platform);
  final bt = _getBinType(platform);

  for (final triple in triples) {
    for (final coin in coins) {
      await runAsync("./build_single.sh", [coin, triple, "-j$nProc"]);
      final path = "$envMoneroCDir"
          "${Platform.pathSeparator}release"
          "${Platform.pathSeparator}$coin"
          "${Platform.pathSeparator}${triple}_libwallet2_api_c.$bt";
      await runAsync("unxz", ["-f", "$path.xz"]);
    }
  }

  Directory.current = thisDir;

  final dir = Directory("$envProjectDir${Platform.pathSeparator}bin")
    ..createSync(recursive: true);

  // copy to built_outputs as required
  switch (platform) {
    // case "macos":
    //   final xmrDylib = "$envMoneroCDir"
    //       "${Platform.pathSeparator}release"
    //       "${Platform.pathSeparator}monero"
    //       "${Platform.pathSeparator}host-apple-darwin_libwallet2_api_c.dylib";
    //   final wowDylib = "$envMoneroCDir"
    //       "${Platform.pathSeparator}release"
    //       "${Platform.pathSeparator}wownero"
    //       "${Platform.pathSeparator}host-apple-darwin_libwallet2_api_c.dylib";
    //
    //   await createFramework(
    //     frameworkName: "MoneroWallet",
    //     pathToDylib: xmrDylib,
    //     targetDirFrameworks: dir.path,
    //   );
    //   await createFramework(
    //     frameworkName: "WowneroWallet",
    //     pathToDylib: wowDylib,
    //     targetDirFrameworks: dir.path,
    //   );
    //
    //   break;

    case "linux":
      for (final coin in coins) {
        await runAsync(
          "cp",
          [
            "$envMoneroCDir"
                "${Platform.pathSeparator}release"
                "${Platform.pathSeparator}$coin"
                "${Platform.pathSeparator}x86_64-linux-gnu_libwallet2_api_c.so",
            "${dir.path}"
                "${Platform.pathSeparator}${coin}_libwallet2_api_c.so",
          ],
        );
      }
      break;

    case "windows":
      await runAsync(
        "cp",
        [
          "$envMoneroCDir"
              "${Platform.pathSeparator}release"
              "${Platform.pathSeparator}monero"
              "${Platform.pathSeparator}x86_64-w64-mingw32_libwallet2_api_c.dll",
          "${dir.path}"
              "${Platform.pathSeparator}monero_libwallet2_api_c.dll",
        ],
      );
      await runAsync(
        "cp",
        [
          "$envMoneroCDir"
              "${Platform.pathSeparator}release"
              "${Platform.pathSeparator}wownero"
              "${Platform.pathSeparator}x86_64-w64-mingw32_libwallet2_api_c.dll",
          "${dir.path}"
              "${Platform.pathSeparator}wownero_libwallet2_api_c.dll",
        ],
      );

      final polyPath = "$envMoneroCDir"
          "${Platform.pathSeparator}release"
          "${Platform.pathSeparator}wownero"
          "${Platform.pathSeparator}x86_64-w64-mingw32_libpolyseed.dll";
      if (File("$polyPath.xz").existsSync()) {
        await runAsync("unxz", ["-f", "$polyPath.xz"]);
      }
      await runAsync(
        "cp",
        [
          polyPath,
          "${dir.path}"
              "${Platform.pathSeparator}libpolyseed.dll",
        ],
      );

      final sspPath = "$envMoneroCDir"
          "${Platform.pathSeparator}release"
          "${Platform.pathSeparator}wownero"
          "${Platform.pathSeparator}x86_64-w64-mingw32_libssp-0.dll";

      if (File("$sspPath.xz").existsSync()) {
        await runAsync("unxz", ["-f", "$sspPath.xz"]);
      }
      await runAsync(
        "cp",
        [
          sspPath,
          "${dir.path}"
              "${Platform.pathSeparator}libssp-0.dll",
        ],
      );

      final pThreadPath = "$envMoneroCDir"
          "${Platform.pathSeparator}release"
          "${Platform.pathSeparator}wownero"
          "${Platform.pathSeparator}x86_64-w64-mingw32_libwinpthread-1.dll";

      if (File("$pThreadPath.xz").existsSync()) {
        await runAsync("unxz", ["-f", "$pThreadPath.xz"]);
      }
      await runAsync(
        "cp",
        [
          pThreadPath,
          "${dir.path}"
              "${Platform.pathSeparator}libwinpthread-1.dll",
        ],
      );
      break;

    default:
      throw Exception("Not sure how you got this far tbh");
  }
}

List<String> _getTriples(String platform) {
  switch (platform) {
    case "android":
      return [
        "x86_64-linux-android",
        "armv7a-linux-androideabi",
        "aarch64-linux-android",
      ];

    case "ios":
      return ["host-apple-ios"];

    case "macos":
      return ["host-apple-darwin"];

    case "linux":
      return ["x86_64-linux-gnu"];

    case "windows":
      return ["x86_64-w64-mingw32"];

    default:
      throw ArgumentError(platform, "platform");
  }
}

String _getNProc(String platform) {
  final int nProc;
  if (platform == "ios" || platform == "macos") {
    final result = Process.runSync("sysctl", ["-n", "hw.physicalcpu"]);
    if (result.exitCode != 0) {
      throw Exception("code=${result.exitCode}, stderr=${result.stderr}");
    }
    nProc = int.parse(result.stdout.toString());
  } else {
    final result = Process.runSync("nproc", []);
    if (result.exitCode != 0) {
      throw Exception("code=${result.exitCode}, stderr=${result.stderr}");
    }
    nProc = int.parse(result.stdout.toString());
  }

  switch (platform) {
    case "android":
    case "linux":
      return max(1, (nProc * 0.8).floor()).toString();

    case "ios":
    case "macos":
    case "windows":
      return nProc.toString();

    default:
      throw ArgumentError(platform, "platform");
  }
}

String _getBinType(String platform) {
  switch (platform) {
    case "android":
    case "linux":
      return "so";

    case "windows":
      return "dll";

    case "ios":
    case "macos":
      return "dylib";

    default:
      throw ArgumentError(platform, "platform");
  }
}

/// run a system process
Future<void> runAsync(String command, List<String> arguments) async {
  final process = await Process.start(command, arguments);

  process.stdout.transform(SystemEncoding().decoder).listen((data) {
    l('[stdout]: $data');
  });

  process.stderr.transform(SystemEncoding().decoder).listen((data) {
    l('[stderr]: $data');
  });

  // Wait for the process to complete
  final exitCode = await process.exitCode;

  if (exitCode != 0) {
    l("$command exited with code $exitCode");
    exit(exitCode);
  }
}

/// create some build dirs if they don't already exist
Future<void> createBuildDirs() async {
  await Future.wait([
    Directory(envBuildDir).create(recursive: true),
    Directory(envOutputsDir).create(recursive: true),
  ]);
}

/// extremely basic logger
void l(Object? o) {
  // ignore: avoid_print
  print(o);
}

Future<void> prepareMoneroC() async {
  await createBuildDirs();

  final moneroCDir = Directory(envMoneroCDir);
  if (moneroCDir.existsSync()) {
    // TODO: something?
    l("monero_c dir already exists");
    return;
  } else {
    // Change directory to BUILD_DIR
    Directory.current = envBuildDir;

    // Clone the monero_c repository
    await runAsync('git', [
      'clone',
      kMoneroCRepo,
    ]);

    // Change directory to MONERO_C_DIR
    Directory.current = moneroCDir;

    // Checkout specific commit and reset
    await runAsync('git', ['checkout', kMoneroCHash]);
    await runAsync('git', ['reset', '--hard']);

    // Configure submodules
    await runAsync('git', [
      'config',
      'submodule.libs/wownero.url',
      'https://git.cypherstack.com/Cypher_Stack/wownero',
    ]);
    await runAsync('git', [
      'config',
      'submodule.libs/wownero-seed.url',
      'https://git.cypherstack.com/Cypher_Stack/wownero-seed',
    ]);

    // Update submodules
    await runAsync(
      'git',
      ['submodule', 'update', '--init', '--force', '--recursive'],
    );

    // Apply patches
    await runAsync('./apply_patches.sh', ['monero']);
    await runAsync('./apply_patches.sh', ['wownero']);
  }
}
