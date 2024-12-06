# `churner`
A command-line tool written in Dart for automated Monero coin churning.

## Overview
`churner` implements a churning strategy that:

1. Creates a transaction spending one output/key image at a time.
2. Analyzes the age of a random decoy input.
3. Broadcasts transaction only when the decoy input is older than the real input.
4. Repeats the process automatically.

## Prerequisites
- Dart SDK ^3.5.4.
- Monero node (local or remote; local HIGHLY recommended).
- `cs_monero` and underlying `monero_c` requirements: refer to their respective 
  repositories for installation instructions.

## Getting started
```bash
git clone https://github.com/cypherstack/churner
cd churner
dart run tools/build.dart
dart run bin/churner.dart --help
```

## Usage
```bash
dart churner.dart <flags> [arguments]
```

### Required Parameters
- `-w, --wallet`: Path to your Monero wallet file
- `-p, --wallet-pass`: Password for the Monero wallet
- `-u, --node`: URL of the Monero node to connect to

### Optional Parameters
- `-n, --network`: Monero network (0=mainnet, 1=testnet, 2=stagenet, default: 0)
- `--node-user`: Username for node authentication
- `--node-pass`: Password for node authentication
- `--ssl`: Use SSL for node connection (default: true)
- `--trusted`: Whether the node is trusted (default: true)
- `-v, --verbose`: Show additional command output
- `-h, --help`: Display usage information
- `--version`: Display version information

### Example
```bash
dart churner.dart -w /path/to/wallet -p wallet_password -u monero.stackwallet.com:18081 --verbose
```

## First Run
When running for the first time with a new wallet path, the tool will:

1. Create a new wallet.
2. Display the seed phrase: save this securely!
3. Begin synchronizing with the network.
4. Start the churning process once synced.

## Security Notes
- Keep your wallet seed phrase secure - it's your only backup.
- Consider running your own Monero node for enhanced privacy.
- The tool will only proceed with churning when privacy conditions are met.
- Wallet files are encrypted with your provided password.

## License
MIT License - See LICENSE file for details.

## Development
Built using:
- [`cs_monero`](https://pub.dev/packages/cs_monero): Dart bindings for Monero's 
  `wallet2`, powered by [`monero_c`](https://github.com/cypherstack/monero_c).
- [`monero_rpc`](https://pub.dev/packages/monero_rpc): Monero RPC client.
- [`digest_auth`](https://pub.dev/packages/digest_auth): For optional RPC auth.
- [`ascii_qr`](https://pub.dev/packages/ascii_qr): Pure Dart ASCII QR codes.
