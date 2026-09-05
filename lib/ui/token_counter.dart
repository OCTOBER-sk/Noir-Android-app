import 'package:flutter/material.dart';
import 'package:noir_android_app/core/constants.dart';

/// A small monochrome widget rendering live token, cost, and latency data.
class TokenCounter extends StatelessWidget {
  /// Input (prompt) tokens consumed in the current session.
  final int inputTokens;

  /// Output (completion) tokens consumed in the current session.
  final int outputTokens;

  /// Accumulated cost in USD (0.0 on free tiers).
  final double costUsd;

  /// Creates a new [TokenCounter].
  const TokenCounter({
    super.key,
    required this.inputTokens,
    required this.outputTokens,
    required this.costUsd,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[
      Text('in ${inputTokens}', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(width: 8),
      Text('out ${outputTokens}', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(width: 8),
      Text('\$${costUsd.toStringAsFixed(2)}', style: Theme.of(context).textTheme.bodySmall),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: NoirColors.gray700),
      child: Row(mainAxisSize: MainAxisSize.min, children: parts),
    );
  }
}
