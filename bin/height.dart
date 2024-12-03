import 'package:monero_rpc/src/daemon_rpc.dart';

void main() async {
  final daemonRpc = DaemonRpc(
    'http://localhost:18081/json_rpc', // Replace with your Monero daemon URL.
    username: 'user', // Replace with your username.
    password: 'password', // Replace with your password.
  );

  try {
    final result = await daemonRpc.call('get_info', {});
    print('Height: ${result['height']}');
  } catch (e) {
    print('Error: $e');
  }
}
