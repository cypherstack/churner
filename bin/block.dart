// RingCT was activated at height 1220516.

import 'package:monero_rpc/src/daemon_rpc.dart';

void main() async {
  final daemonRpc = DaemonRpc(
    'http://localhost:18081/json_rpc', // Replace with your Monero daemon URL.
    username: 'user', // Replace with your username.
    password: 'password', // Replace with your password.
  );

  try {
    final result = await daemonRpc
        .call('get_block', {'height': '1220516', 'decode_as_json': true});
    print(result);

    if (!result.containsKey('tx_hashes')) {
      throw Exception('No tx_hashes found in get_block response.');
    }
    try {
      final txsResult = await daemonRpc.postToEndpoint('/get_transactions', {
        'txs_hashes': "[${result['tx_hashes'].toString()}]",
        'decode_as_json': true,
      });
      print(txsResult);
    } catch (e) {
      print('Error: $e');
    }
  } catch (e) {
    print('Error: $e');
  }
}
