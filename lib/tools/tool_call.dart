/// Canonical tool invocation passed through the gateway (V2.1 §8 B4).
class ToolCall {
  /// Tool name, e.g. `readScreen`.
  final String name;

  /// Arguments for the tool.
  final Map<String, dynamic> arguments;

  /// Execution class: `'uiBound'` or `'backgroundSafe'`.
  final String executionClass;

  /// Permissions required to execute this tool.
  final List<String> requiredPermissions;

  /// Pre-classified risk level in `0..3`.
  final int riskLevel;

  /// Creates a new canonical [ToolCall].
  const ToolCall({
    required this.name,
    required this.arguments,
    required this.executionClass,
    required this.requiredPermissions,
    required this.riskLevel,
  });
}
