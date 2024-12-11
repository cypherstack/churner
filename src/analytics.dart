import 'dart:convert';
import 'dart:io';

import 'package:cs_monero/cs_monero.dart'; // For Output.

import 'utils.dart';

/// Represents a single churned output with its identifier and count.
class ChurnRecord {
  final String txHash;
  final int outputIndex;
  int count;

  ChurnRecord({
    required this.txHash,
    required this.outputIndex,
    this.count = 0,
  });

  Map<String, dynamic> toJson() => {
        'txHash': txHash,
        'outputIndex': outputIndex,
        'count': count,
      };

  factory ChurnRecord.fromJson(Map<String, dynamic> json) {
    return ChurnRecord(
      txHash: json['txHash'] as String,
      outputIndex: json['outputIndex'] as int,
      count: json['count'] as int,
    );
  }
}

/// A class for managing and summarizing churn history.
class ChurnHistory {
  final Map<String, ChurnRecord> _records = {};
  final String historyPath;
  final bool verbose;

  ChurnHistory(String walletPath, this.verbose)
      : historyPath = '$walletPath.json';

  String _getOutputKey(String txHash, int outputIndex) {
    return '$txHash:$outputIndex';
  }

  /// Load churn history from file.
  void load() {
    try {
      final file = File(historyPath);
      if (file.existsSync()) {
        final content = file.readAsStringSync();
        if (content.isEmpty) {
          return;
        }

        try {
          final data = jsonDecode(content) as Map<String, dynamic>;
          _records.clear();

          data.forEach((key, value) {
            try {
              final record =
                  ChurnRecord.fromJson(value as Map<String, dynamic>);
              _records[key] = record;
            } catch (e) {
              l("Warning: Failed to parse record $key: $e");
            }
          });
        } catch (e) {
          // If the file is corrupted, create a simple .bak backup and restart.
          if (file.existsSync()) {
            file.copySync('${historyPath}.bak');
          }
          _records.clear();
          l("Error: Corrupted churn history file.  Backup created at ${historyPath}.bak.");
        }
      }
    } catch (e) {
      l("Warning: Failed to load churn history: $e");
    }
  }

  /// Save churn history to file.
  void save() {
    try {
      final Map<String, dynamic> data = {};
      _records.forEach((key, record) {
        data[key] = record.toJson();
      });

      // Write to temporary file first.
      final tempPath = '$historyPath.tmp';
      File(tempPath).writeAsStringSync(jsonEncode(data));

      // Then atomically move it to the final location.
      File(tempPath).renameSync(historyPath);

      if (verbose) {
        print("Churn history saved to $historyPath.");
      }
    } catch (e, s) {
      l("Warning: Failed to save churn history: $e\n$s");
    }
  }

  /// Look up how many times an output has been churned.
  int getChurnCount(Output output, {int outputIndex = 0}) {
    final key = _getOutputKey(output.hash, outputIndex);
    return _records[key]?.count ?? 0;
  }

  /// Record that an output was churned.
  void recordChurn(Output oldOutput, String newTxHash,
      {int oldOutputIndex = 0, int newOutputIndex = 0}) {
    final oldKey = _getOutputKey(oldOutput.hash, oldOutputIndex);
    final oldCount = _records[oldKey]?.count ?? 0;

    final newKey = _getOutputKey(newTxHash, newOutputIndex);
    _records[newKey] = ChurnRecord(
        txHash: newTxHash, outputIndex: newOutputIndex, count: oldCount + 1);

    if (verbose) {
      print(
          "Churned output $oldKey -> $newKey.  (Churned ${oldCount + 1} times.)");
    }

    save();
  }

  /// Return a summary of churn records.
  Map<String, dynamic> getAnalytics() {
    if (_records.isEmpty) {
      return {
        'totalOutputs': 0,
        'totalChurns': 0,
        'averageChurns': 0,
        'maxChurns': 0,
      };
    }

    int totalChurns = 0;
    int maxChurns = 0;

    for (final record in _records.values) {
      totalChurns += record.count;
      maxChurns = maxChurns > record.count ? maxChurns : record.count;
    }

    return {
      'totalOutputs': _records.length,
      'totalChurns': totalChurns,
      'averageChurns': totalChurns / _records.length,
      'maxChurns': maxChurns,
    };
  }
}
