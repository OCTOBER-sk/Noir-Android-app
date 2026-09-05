import 'skill_proposal.dart';
import 'skill_repository.dart';

/// Executes stored skills, enforcing the runtime safety gate (V2.1 §A3).
///
/// Only skills whose [Skill.riskLevel] is [SkillRiskLevel.safe] may execute.
/// [SkillRiskLevel.review] and [SkillRiskLevel.dangerous] skills always
/// throw and require out-of-band user confirmation.
class SkillExecutor {
  /// The repository skills are loaded from.
  final SkillRepository repository;

  /// Optional callback invoked with each step as the skill runs.
  final void Function(String step)? onStep;

  /// Creates a [SkillExecutor] bound to [repository].
  SkillExecutor(this.repository, {this.onStep});

  /// Executes the skill identified by [id].
  ///
  /// Throws [StateError] if the skill is not found or is not [safe].
  Future<void> executeSkill(String id) async {
    final skill = repository.get(id);
    if (skill == null) {
      throw StateError('Skill not found: $id');
    }
    if (skill.riskLevel != SkillRiskLevel.safe) {
      throw StateError(
        'Refusing to execute non-safe skill ${skill.id} '
        '(risk=${skill.riskLevel})',
      );
    }
    for (final step in skill.steps) {
      onStep?.call(step);
      // No real device work in the thin slice; steps are recorded only.
      await Future<void>.delayed(Duration.zero);
    }
  }
}
