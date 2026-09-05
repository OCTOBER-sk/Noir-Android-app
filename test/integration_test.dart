import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/memory/layers.dart';
import 'package:noir_android_app/providers/adapters/openrouter_adapter.dart';
import 'package:noir_android_app/providers/llm_provider.dart';
import 'package:noir_android_app/providers/usage_tracker.dart';
import 'package:noir_android_app/skill/skill_proposal.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';

void main() {
  test('processGoal round-trip writes to memory and skill repository',
      () async {
    final runtime = AgentRuntime();
    await runtime.processGoal('open Settings', ['find app', 'tap icon']);

    final skill = runtime.skills.get('open Settings');
    expect(skill, isNotNull);
    expect(skill!.riskLevel, SkillRiskLevel.safe);
    expect(skill.state, 'active');

    final episodic = runtime.memory.getAll(MemoryLayer.episodic);
    expect(episodic, hasLength(1));
    expect(episodic.first.content, contains('open Settings'));
  });

  test('replaySkill is gated by risk level', () async {
    final runtime = AgentRuntime();
    await runtime.processGoal('safe thing', ['s1']);
    await runtime.replaySkill('safe thing');

    runtime.skills.add(Skill(
      id: 'risky',
      name: 'risky',
      description: 'x',
      riskLevel: SkillRiskLevel.review,
      steps: [],
    ));
    expect(runtime.replaySkill('risky'), throwsA(isA<StateError>()));
  });

  test('UsageTracker records and streams', () async {
    final tracker = UsageTracker();
    tracker.recordUsage(Usage(
      inputTokens: 10,
      outputTokens: 5,
      costUsd: 0.0,
      latency: Duration(milliseconds: 200),
    ));
    expect(tracker.entries, hasLength(1));
    expect(tracker.totalCost, equals(0.0));

    final completer = Completer<List<Usage>>();
    final sub = tracker.onUpdated.listen((data) {
      if (!completer.isCompleted) {
        completer.complete(data);
      }
    });

    tracker.recordUsage(Usage(
      inputTokens: 5,
      outputTokens: 3,
      costUsd: 0.0,
      latency: Duration(milliseconds: 100),
    ));

    final result = await completer.future.timeout(Duration(seconds: 1));
    expect(result, hasLength(2));

    await sub.cancel();
    tracker.dispose();
  });

  test('OpenRouter adapter has the right model and capabilities', () {
    final adapter = OpenRouterAdapter(apiKey: 'test');
    expect(adapter.name.toLowerCase(), contains('openrouter'));
    expect(adapter.model, equals(openrouterPoolsideFree));
    expect(adapter.capabilities.streaming, isTrue);
    expect(adapter.capabilities.vision, isFalse);
    expect(adapter.capabilities.toolUse, isFalse);
    expect(adapter.capabilities.contextWindow, greaterThanOrEqualTo(100000));
    expect(adapter.capabilities.costPerMillionInput, equals(0.0));
    expect(adapter.capabilities.costPerMillionOutput, equals(0.0));
  });

  testWidgets(
      'CommandCentreScreen end-to-end: type a message, see it in the list',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: CommandCentreScreen(),
    ));

    final field = find.byType(TextField);
    expect(field, findsOneWidget);

    await tester.enterText(field, 'hello noir');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();

    expect(find.text('hello noir'), findsWidgets);
  });
}
