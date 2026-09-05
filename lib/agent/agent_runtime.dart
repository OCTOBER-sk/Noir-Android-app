import '../memory/layers.dart';
import '../memory/memory_store.dart';
import '../skill/skill_proposal.dart';
import '../skill/skill_repository.dart';
import '../skill/skill_executor.dart';

/// The agent runtime ties together layered memory and the skill loop
/// (V2.1 §A1 + §A3 thin).
///
/// In this thin slice [processGoal] creates a *safe* skill plus an episodic
/// memory item recording the goal, and [replaySkill] delegates to the
/// [SkillExecutor].
class AgentRuntime {
  /// Backing memory store.
  final MemoryStore memory;

  /// Backing skill repository.
  final SkillRepository skills;

  /// Executor bound to [skills].
  final SkillExecutor executor;

  /// Creates an [AgentRuntime]. If [skills] and [executor] are omitted a
  /// fresh repository + executor bound to it are created.
  AgentRuntime._({
    required this.memory,
    required this.skills,
    required this.executor,
  });

  /// Public factory. Builds the runtime so that the auto-created
  /// [SkillExecutor] is bound to the SAME [SkillRepository] instance that
  /// ends up in the [skills] field — otherwise `replaySkill` would search an
  /// empty repository.
  factory AgentRuntime({
    MemoryStore? memory,
    SkillRepository? skills,
    SkillExecutor? executor,
  }) {
    final repo = skills ?? SkillRepository();
    return AgentRuntime._(
      memory: memory ?? MemoryStore(),
      skills: repo,
      executor: executor ?? SkillExecutor(repo),
    );
  }

  /// Processes a natural-language [goal] broken into [steps].
  ///
  /// Creates a safe skill (riskLevel = [SkillRiskLevel.safe]) from the steps
  /// and persists an episodic memory item recording the goal.
  Future<Skill> processGoal(String goal, List<String> steps) async {
    final skill = Skill(
      id: goal,
      name: goal,
      description: goal,
      riskLevel: SkillRiskLevel.safe,
      steps: steps,
      state: 'active',
    );
    skills.add(skill);
    memory.add(MemoryItem(
      content: goal,
      source: 'processGoal',
      layer: MemoryLayer.episodic,
    ));
    return skill;
  }

  /// Replays the skill identified by [id] via the [SkillExecutor].
  Future<void> replaySkill(String id) => executor.executeSkill(id);
}
