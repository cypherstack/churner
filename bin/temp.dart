import 'package:cs_monero/cs_monero.dart';

dummy() async {
  // args to be read from cli TODO
  final pathToWallet = "";
  final password = "";
  final node = "";
  final String? daemonUsername = ""; // should default to null if non existent
  final String? daemonPassword = ""; // should default to null if non existent
  final network = 0; // mainnet
  final ssl = true;
  final trusted = true;

  final walletExists = MoneroWallet.isWalletExist(pathToWallet);
  if (!walletExists) {
    throw Exception("Wallet not found: $pathToWallet");
  }

  final wallet = MoneroWallet.loadWallet(
    path: pathToWallet,
    password: password,
    networkType: network,
  );

  wallet.connect(
    daemonAddress: node,
    trusted: trusted,
    daemonUsername: daemonUsername,
    daemonPassword: daemonPassword,
    useSSL: ssl,
    socksProxyAddress: null, // needed?
  );

  final connected = await wallet.isConnectedToDaemon();
  if (!connected) {
    throw Exception("Failed to connect to daemon: $node");
  }

  wallet.startSyncing();

  // TODO add listeners??
  wallet.startListeners();

  wallet.startAutoSaving();

  // TODO wait for syncing to complete. Either using listeners or polling wallet.isSynced()

  final myOutputs = await wallet.getOutputs(
    includeSpent: false,
    refresh: true,
  );

  // TODO pick an output properly
  final outputToChurn = myOutputs.first;

  final accountIndex = 0; // TODO make this an arg?

  final pending = await wallet.createTx(
    output: Recipient(
      address: wallet
          .getAddress(
            accountIndex: accountIndex,
          )
          .value,
      amount: outputToChurn.value,
    ),
    priority: TransactionPriority.normal, // TODO make this an arg?
    accountIndex: accountIndex,
    preferredInputs: [outputToChurn],
    sweep: true,
  );

  // TODO deserialize `pending.hex` and do things

  // eventually broadcast the tx
  await wallet.commitTx(pending);
}
