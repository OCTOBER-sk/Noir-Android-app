/// Classifies a tool invocation into a 0-3 risk level (V2.1 §7 A6).
class RiskClassifier {
  /// Returns the risk level for [toolName] with the given [args].
  ///
  /// Mapping (V2.1 §A6 thin):
  /// - `readScreen` -> 0
  /// - `tap` -> 1
  /// - `sendMessage` -> 2
  /// - `makePayment` -> 3
  /// Unknown tool names default to 2.
  int classifyRisk(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'readScreen':
        return 0;
      case 'tap':
        return 1;
      case 'sendMessage':
        return 2;
      case 'makePayment':
        return 3;
      default:
        return 2;
    }
  }
}
