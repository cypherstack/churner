import 'dart:io';

import 'package:monero_rpc/monero_rpc.dart';

/// Query the daemon for the current blockchain height.
Future<int> getCurrentHeight(DaemonRpc daemonRpc) async {
  final info = await daemonRpc.postToEndpoint("/get_info", {});
  if (!info.containsKey("height")) {
    throw Exception("Height not found in get_info response.");
  }
  return info["height"] as int;
}

String get libName {
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

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
}

void l(Object? object) {
  // ignore: avoid_print
  print(object);
}
