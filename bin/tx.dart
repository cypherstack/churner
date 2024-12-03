import 'package:monero_rpc/src/daemon_rpc.dart';

void main() async {
  final daemonRpc = DaemonRpc(
    'http://localhost:18081/get_transactions', // Replace with your Monero daemon URL.
    username: 'user', // Replace with your username.
    password: 'password', // Replace with your password.
  );

  try {
    final txsResult = await daemonRpc.postToEndpoint('/get_transactions', {
      'txs_hashes': [
        'd6e48158472848e6687173a91ae6eebfa3e1d778e65252ee99d7515d63090408'
      ],
      'decode_as_json': true,
    });
    print(txsResult);
  } catch (e) {
    print('Error: $e');
  }
}
