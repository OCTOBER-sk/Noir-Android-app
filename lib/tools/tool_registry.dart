import 'tool_call.dart';

/// Registry of available tools and their factories (V2.1 §8 B4).
class ToolRegistry {
  /// Internal map from tool name to factory.
  final Map<String, ToolCall Function()> _factories = {};

  /// Metadata kept for inspection (risk, execution class, permissions).
  final Map<String, int> _riskLevels = {};
  final Map<String, String> _executionClasses = {};
  final Map<String, List<String>> _requiredPermissions = {};

  /// Creates a [ToolRegistry] pre-populated with the thin-slice stub tool.
  ToolRegistry() {
    register(
      'readScreen',
      () => const ToolCall(
        name: 'readScreen',
        arguments: {},
        executionClass: 'uiBound',
        requiredPermissions: ['accessibility'],
        riskLevel: 0,
      ),
      0,
      'uiBound',
      const ['accessibility'],
    );
  }

  /// Registers a tool [name] with the given [factory] and metadata.
  void register(
    String name,
    ToolCall Function() factory,
    int riskLevel,
    String executionClass,
    List<String> requiredPermissions,
  ) {
    _factories[name] = factory;
    _riskLevels[name] = riskLevel;
    _executionClasses[name] = executionClass;
    _requiredPermissions[name] = List<String>.unmodifiable(requiredPermissions);
  }

  /// Looks up the tool named [name] and returns a fresh [ToolCall] or null.
  ToolCall? lookup(String name) {
    final factory = _factories[name];
    if (factory == null) return null;
    return factory();
  }
}
