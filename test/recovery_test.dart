import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/cost_estimator.dart';
import 'package:noir_android_app/agent/recovery_engine.dart';
import 'package:noir_android_app/agent/task_controller.dart';
import 'package:noir_android_app/providers/llm_provider.dart';
import 'package:noir_android_app/providers/usage_tracker.dart';

void main() {
  test('RecoveryEngine returns retryOnce on first call', () async {
    final controller = TaskController();
    final engine = RecoveryEngine(controller);
    final step = await engine.handleError(Exception('fail'),
        toolName: 'tap', args: {});
    expect(step, RecoveryStep.retryOnce);
    controller.dispose();
  });

  test('RecoveryEngine returns rePlan after maxRetries+1 calls', () async {
    final controller = TaskController();
    final engine = RecoveryEngine(controller, maxRetries: 2);
    await engine.handleError(Exception('fail'), toolName: 'tap');
    await engine.handleError(Exception('fail'), toolName: 'tap');
    final step = await engine.handleError(Exception('fail'), toolName: 'tap');
    expect(step, RecoveryStep.rePlan);
    controller.dispose();
  });

  test('RecoveryEngine returns askUser after that', () async {
    final controller = TaskController();
    final engine = RecoveryEngine(controller);
    await engine.handleError(Exception('fail'), toolName: 'tap');
    await engine.handleError(Exception('fail'), toolName: 'tap');
    await engine.handleError(Exception('fail'), toolName: 'tap');
    final step = await engine.handleError(Exception('fail'), toolName: 'tap');
    expect(step, RecoveryStep.askUser);
    controller.dispose();
  });

  test('RecoveryEngine.reset clears attempt counter', () async {
    final controller = TaskController();
    final engine = RecoveryEngine(controller);
    await engine.handleError(Exception('fail'), toolName: 'tap');
    await engine.handleError(Exception('fail'), toolName: 'tap');
    engine.reset('tap');
    final step = await engine.handleError(Exception('fail'), toolName: 'tap');
    expect(step, RecoveryStep.retryOnce);
    controller.dispose();
  });

  test('CostEstimator.canAfford returns true for free model under cap', () {
    final tracker = UsageTracker();
    final estimator = CostEstimator(tracker);
    final can = estimator.canAfford(openrouterPoolsideFree, 100, 100);
    expect(can, isTrue);
    final estimate = estimator.estimate(openrouterPoolsideFree, 100, 100);
    expect(estimate.costUsd, equals(0.0));
    expect(estimate.totalTokens, equals(200));
    expect(estimate.wouldExceedDailyCap, isFalse);
    expect(estimate.wouldExceedDollarCap, isFalse);
    tracker.dispose();
  });

  test('CostEstimator.canAfford returns false when daily token cap would be exceeded',
      () {
    final tracker = UsageTracker();
    tracker.recordUsage(Usage(
      inputTokens: 999900,
      outputTokens: 0,
      costUsd: 0.0,
      latency: const Duration(milliseconds: 10),
    ));
    final estimator = CostEstimator(tracker, dailyCap: 1000000);
    final can = estimator.canAfford(openrouterPoolsideFree, 200, 0);
    expect(can, isFalse);
    final estimate = estimator.estimate(openrouterPoolsideFree, 200, 0);
    expect(estimate.wouldExceedDailyCap, isTrue);
    tracker.dispose();
  });
}
