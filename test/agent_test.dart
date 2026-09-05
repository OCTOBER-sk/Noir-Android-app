import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/task_controller.dart';
import 'package:noir_android_app/safety/policy_engine.dart';
import 'package:noir_android_app/safety/risk_classifier.dart';
import 'package:noir_android_app/tools/tool_call.dart';
import 'package:noir_android_app/tools/tool_gateway.dart';
import 'package:noir_android_app/tools/tool_registry.dart';

void main() {
  test('TaskController transitions idle -> planning on startTask', () async {
    final controller = TaskController();
    expect(controller.state, TaskState.idle);
    await controller.startTask('test goal', ['step1', 'step2']);
    expect(controller.state, TaskState.planning);
    expect(controller.activeTaskId, 'test goal');
    expect(controller.startedAt, isNotNull);
    controller.dispose();
  });

  test('TaskController emits state events on the broadcast stream', () async {
    final controller = TaskController();
    final events = <String>[];
    final sub = controller.events.listen(events.add);

    await controller.startTask('ev goal', ['s1']);
    // Allow microtask for broadcast delivery.
    await Future<void>.delayed(Duration.zero);

    expect(events, contains('idle->planning'));

    await sub.cancel();
    controller.dispose();
  });

  test('TaskController terminal state has correct outcome', () async {
    final controller = TaskController();
    await controller.startTask('terminal goal', ['s1']);
    await controller.completeTask(TaskOutcome.completed);
    expect(controller.state, TaskState.terminal);
    expect(controller.outcome, TaskOutcome.completed);
    expect(controller.endedAt, isNotNull);
    controller.dispose();
  });

  test('RiskClassifier maps tool names to correct risk levels', () {
    final c = RiskClassifier();
    expect(c.classifyRisk('readScreen', {}), 0);
    expect(c.classifyRisk('tap', {}), 1);
    expect(c.classifyRisk('sendMessage', {}), 2);
    expect(c.classifyRisk('makePayment', {}), 3);
    expect(c.classifyRisk('unknownTool', {}), 2);
  });

  test('PolicyEngine allows risk 0 without confirmation', () {
    final engine = PolicyEngine();
    final d = engine.evaluate(
      risk: 0,
      executionClass: 'uiBound',
      requiredPermissions: ['accessibility'],
      biometricAvailable: true,
    );
    expect(d.allowed, isTrue);
    expect(d.requiresConfirmation, isFalse);
    expect(d.requiresBiometric, isFalse);
  });

  test('PolicyEngine denies risk 3 when biometric is unavailable', () {
    final engine = PolicyEngine();
    final d = engine.evaluate(
      risk: 3,
      executionClass: 'uiBound',
      requiredPermissions: ['accessibility'],
      biometricAvailable: false,
    );
    expect(d.allowed, isFalse);
    expect(d.reason, contains('biometric unavailable'));
    expect(d.requiresConfirmation, isTrue);
    expect(d.requiresBiometric, isTrue);
  });

  test('ToolGateway dispatches a safe uiBound tool to a stub executor',
      () async {
    final registry = ToolRegistry();
    final policy = PolicyEngine();
    final gateway = ToolGateway(registry: registry, policy: policy);

    final call = registry.lookup('readScreen');
    expect(call, isNotNull);
    expect(call!.executionClass, 'uiBound');
    expect(call.riskLevel, 0);

    final result = await gateway.execute(call);
    expect(result, contains('tool:readScreen executed'));
  });

  test('ToolGateway throws StateError when policy denies', () async {
    final registry = ToolRegistry();
    // Custom engine that always denies.
    final denyingPolicy = _DenyingPolicyEngine();
    final gateway = ToolGateway(registry: registry, policy: denyingPolicy);

    const call = ToolCall(
      name: 'makePayment',
      arguments: {'amount': 100},
      executionClass: 'uiBound',
      requiredPermissions: ['accessibility'],
      riskLevel: 3,
    );

    expect(gateway.execute(call), throwsA(isA<StateError>()));
  });
}

/// Policy engine that always denies for the deny test.
class _DenyingPolicyEngine extends PolicyEngine {
  @override
  PolicyDecision evaluate({
    required int risk,
    required String executionClass,
    required List<String> requiredPermissions,
    required bool biometricAvailable,
  }) {
    return const PolicyDecision(
      allowed: false,
      requiresConfirmation: true,
      requiresBiometric: true,
      reason: 'policy denied for test',
    );
  }
}
