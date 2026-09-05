import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/skill/skill_proposal.dart';
import 'package:noir_android_app/skill/skill_repository.dart';
import 'package:noir_android_app/skill/skill_executor.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';

void main() {
  test('SkillRepository CRUD', () {
    final repo = SkillRepository();
    final skill = Skill(
      id: 's1',
      name: 'open app',
      description: 'opens an app',
      riskLevel: SkillRiskLevel.safe,
      steps: ['tap icon'],
    );
    expect(repo.getAll(), isEmpty);
    repo.add(skill);
    expect(repo.getAll(), hasLength(1));
    expect(repo.get('s1'), same(skill));
    expect(repo.remove('s1'), isTrue);
    expect(repo.get('s1'), isNull);
  });

  test('SkillExecutor executes safe skills only', () {
    final repo = SkillRepository();
    final steps = <String>[];
    final executor = SkillExecutor(repo, onStep: steps.add);
    final safe = Skill(
      id: 'safe',
      name: 'safe',
      description: 'safe',
      riskLevel: SkillRiskLevel.safe,
      steps: ['step one', 'step two'],
    );
    repo.add(safe);
    expect(safe.riskLevel, SkillRiskLevel.safe);

    // review skill must throw
    final review = Skill(
      id: 'review',
      name: 'review',
      description: 'review',
      riskLevel: SkillRiskLevel.review,
      steps: [],
    );
    repo.add(review);

    expect(executor.executeSkill('safe'), completes);
    expect(executor.executeSkill('review'),
        throwsA(isA<StateError>()));
    expect(executor.executeSkill('missing'),
        throwsA(isA<StateError>()));
  });

  test('AgentRuntime.processGoal creates safe skill and episodic memory',
      () async {
    final runtime = AgentRuntime();
    final skill = await runtime.processGoal('do a thing', ['a', 'b']);
    expect(skill.riskLevel, SkillRiskLevel.safe);
    expect(skill.state, 'active');
    expect(runtime.skills.get(skill.id), same(skill));
  });

  test('AgentRuntime.replaySkill delegates to executor safety gate', () async {
    final runtime = AgentRuntime();
    await runtime.processGoal('ok', ['step']);
    expect(runtime.replaySkill('ok'), completes);
    await runtime.processGoal('review me', ['step'])
        .then((s) => runtime.skills.add(Skill(
              id: 'manual-review',
              name: 'manual-review',
              description: '',
              riskLevel: SkillRiskLevel.review,
              steps: [],
            )));
    expect(runtime.replaySkill('manual-review'),
        throwsA(isA<StateError>()));
  });
}
