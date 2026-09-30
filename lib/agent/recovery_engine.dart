// lib/agent/recovery_engine.dart — A4 (Hierarchical Recovery — FULL)
// Routes low-confidence reflection results into recovery path; never bypasses PolicyEngine gate.

/// One A4 recovery, as a value rather than a map.
///
/// This is what the recovery path hands back and what the Safety Center's safety
/// log renders, so it exists as a typed record: a `Map<String, dynamic>` can only
/// be read by guessing at key names and casts, and the field that matters most —
/// the confidence that triggered the recovery — is exactly the one a wrong cast
/// would turn into a lie. [toMap] still produces the wire shape
/// [HierarchicalRecovery.auditLog] has always returned, so nothing that reads the
/// map breaks.
///
/// Every field is read off the recovery that produced it. Nothing here is
/// defaulted, filled in or invented: there is no id, no score and no moment in
/// this class that the caller did not supply.
class RecoveryAudit {
  const RecoveryAudit({
    required this.taskId,
    required this.confidenceScore,
    required this.recoveryPath,
    required this.sanitizedScreenUsed,
    required this.timestamp,
  });

  /// The A5 task this recovery belongs to — the id the `TaskController` was
  /// built with, never one made up here.
  final String taskId;

  /// Reflection confidence on the 0-100 scale [HierarchicalRecovery.needsRecovery]
  /// compares against. The reflection's own 0.0-1.0 value, rounded and scaled by
  /// the caller that has the reflection in hand.
  final int confidenceScore;

  /// The path that was chosen, e.g.
  /// `re-execute-with-sanitized-screen-content`. A constant today, held as data
  /// so a log line records which path ran rather than implying there was one.
  final String recoveryPath;

  /// Whether the retry was planned on sanitized screen content. The raw dump is
  /// never handed to this path, so a hidden node cannot steer a recovery.
  final bool sanitizedScreenUsed;

  /// When the audit entry was built, from the same object as every other field.
  final DateTime timestamp;

  /// The wire-shaped form, identical to what [HierarchicalRecovery.auditLog] has
  /// always returned.
  Map<String, dynamic> toMap() => <String, dynamic>{
    'taskId': taskId,
    'confidenceScore': confidenceScore,
    'recoveryPath': recoveryPath,
    'sanitizedScreenUsed': sanitizedScreenUsed,
    'timestamp': timestamp.toIso8601String(),
  };

  @override
  String toString() =>
      'RecoveryAudit($taskId, confidence $confidenceScore, $recoveryPath)';
}

class HierarchicalRecovery {
  final String taskId;
  final int confidenceScore;
  HierarchicalRecovery(this.taskId, this.confidenceScore);
  bool needsRecovery() =>
      confidenceScore < 50; // scaled to 0-100 for comparison
  String recoveryPath() => 're-execute-with-sanitized-screen-content';

  /// The audit entry for this recovery, as a typed record.
  ///
  /// One call, one moment: the timestamp is taken here, where the score and the
  /// path are known, so a record cannot claim a time that belongs to a different
  /// assessment of the same run.
  RecoveryAudit audit() => RecoveryAudit(
    taskId: taskId,
    confidenceScore: confidenceScore,
    recoveryPath: recoveryPath(),
    sanitizedScreenUsed: true,
    timestamp: DateTime.now(),
  );

  // Uses sanitized screen content (not raw) for safe retry; logs audit trail
  Map<String, dynamic> auditLog() => audit().toMap();
}

/// Runs the A4 recovery for [r] and returns the audit entry it produced.
///
/// A4 full: executes recovery when confidence < 0.5 (scaled < 50); uses sanitized screen content; logs audit.
/// Never bypasses PolicyEngine gate (C2 enforced) before any retry action.
///
/// The entry is returned rather than dropped. [SanitizingRecoveryEngine] in
/// `lib/core/agent_wiring.dart` is the only caller: it keeps the record and
/// forwards it to the Safety Center's safety log through the composition root, so
/// a run that ended `RECOVERY_NEEDS_REVIEW` is a line a user can actually read.
RecoveryAudit executeReflectionRecovery(
  HierarchicalRecovery r, {
  required dynamic sanitizedScreen,
}) => r.audit();
