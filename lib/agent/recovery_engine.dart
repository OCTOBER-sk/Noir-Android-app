// lib/agent/recovery_engine.dart — A4 (Hierarchical Recovery)
// Routes low-confidence reflection results into recovery path.
class HierarchicalRecovery {
  final String taskId; final int confidenceScore;
  HierarchicalRecovery(this.taskId, this.confidenceScore);
  bool needsRecovery() => confidenceScore < 0.5;
  String recoveryPath() => 're-execute-with-sanitized-screen-content';
}
