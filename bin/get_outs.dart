import 'package:monero_rpc/monero_rpc.dart';

void main() async {
  final daemonRpc = DaemonRpc('http://monero.stackwallet.com:18081/json_rpc');

  try {
    // Call get_outs via helper method with list of relative key offsets (as
    // deserialized from a transaction).
    try {
      final getOutsResult =
          await daemonRpc.getOuts(convertRelativeToAbsolute([5164903, 123]));
      print('Height: ${getOutsResult.outs.first.height}'); // Read: age.
      print('TxID: ${getOutsResult.outs.first.txid}');
      // Identify our output from this list using known information.
    } catch (e) {
      print('Error: $e');
    }
  } catch (e) {
    print('Error: $e');
  }
}
