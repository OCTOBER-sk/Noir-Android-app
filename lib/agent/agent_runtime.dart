// lib/agent/agent_runtime.dart — A6 pipeline + A12 reflection skeleton + A6b undo window
import 'package:.../safety/policy_engine.dart';
import 'package:.../safety/screen_content_sanitizer.dart';

class AgentRuntime {
  final PolicyEngine engine = PolicyEngine();
  void run(dynamic proposal) {
    final gate = engine.gate(proposal, riskLevel: proposal['riskLevel'] ?? 0);
    if (gate.needsBiometric) { /* A8 biometric */ }
    // A12: compare intended vs observed; low confidence -> recovery
    // A6b undo: 5s cancellable for riskLevel >= 1
  }
}
