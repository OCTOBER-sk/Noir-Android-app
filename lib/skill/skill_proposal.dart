/// Counter backing the zero-dependency ID generator.
int _skillIdCounter = 0;

/// Generates a monotonically unique skill id without external packages.
String _generateSkillId() {
  _skillIdCounter += 1;
  return 'skill_${DateTime.now().microsecondsSinceEpoch}_$_skillIdCounter';
}

/// Risk classification for a proposed or stored skill (V2.1 §A3).
///
/// The runtime enforces: only [safe] skills may execute automatically;
/// [review] and [dangerous] skills always require explicit user
/// confirmation (and biometric gating for sensitive actions).
enum SkillRiskLevel {
  /// Safe: deterministic, non-sensitive, reversible. May execute freely.
  safe,

  /// Review: requires user confirmation before execution.
  review,

  /// Dangerous: high-risk; requires confirmation + biometric gate.
  dangerous,
}

/// A proposal to create or update a skill, submitted before user promotion.
class SkillProposal {
  /// Unique proposal identifier.
  final String id;

  /// Human-readable name of the proposed skill.
  final String name;

  /// Natural-language description of what the skill does.
  final String description;

  /// Risk level governing how the skill may be executed.
  final SkillRiskLevel riskLevel;

  /// Ordered step plan the skill would execute.
  final List<String> steps;

  /// Creates a new [SkillProposal].
  ///
  /// If [id] is omitted, a unique id is generated automatically.
  SkillProposal({
    String? id,
    required this.name,
    required this.description,
    required this.riskLevel,
    required this.steps,
  })  : id = id ?? _generateSkillId();
}

/// A stored, executable procedural skill (candidate → … → active/degraded).
class Skill {
  /// Stable skill identifier.
  final String id;

  /// Human-readable name.
  final String name;

  /// Natural-language description.
  final String description;

  /// Risk level gating execution.
  final SkillRiskLevel riskLevel;

  /// Ordered step plan.
  final List<String> steps;

  /// Lifecycle state: candidate, draft, active, degraded, needsReview.
  final String state;

  /// Human-meaningful success score in `[0.0, 1.0]` from execution history.
  final double successScore;

  /// Creates a new [Skill].
  Skill({
    required this.id,
    required this.name,
    required this.description,
    required this.riskLevel,
    required this.steps,
    this.state = 'candidate',
    this.successScore = 0.0,
  });
}
