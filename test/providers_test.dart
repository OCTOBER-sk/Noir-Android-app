import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/providers/llm_provider.dart';
import 'package:noir_android_app/providers/adapters/openrouter_adapter.dart';
import 'package:noir_android_app/providers/usage_tracker.dart';

void main() {
  test('OpenRouter adapter instantiates with the correct model and key', () {
    final adapter = OpenRouterAdapter(apiKey: 'test-key-not-real');
    expect(adapter.name, equals('OpenRouter'));
    expect(adapter.model, equals(openrouterPoolsideFree));
  });

  test('OpenRouter adapter advertises free-tier capabilities', () {
    final adapter = OpenRouterAdapter(apiKey: 'test-key-not-real');
    expect(adapter.capabilities.streaming, isTrue);
    expect(adapter.capabilities.vision, isFalse);
    expect(adapter.capabilities.toolUse, isFalse);
    expect(adapter.capabilities.contextWindow, equals(262144));
    expect(adapter.capabilities.costPerMillionInput, equals(0.0));
    expect(adapter.capabilities.costPerMillionOutput, equals(0.0));
  });

  test('UsageTracker records free-tier usage with cost 0.0', () {
    final tracker = UsageTracker();
    final usage = Usage(
      inputTokens: 10,
      outputTokens: 20,
      costUsd: 0.0,
      latency: const Duration(milliseconds: 50),
    );
    tracker.recordUsage(usage);
    expect(tracker.entries, hasLength(1));
    expect(tracker.entries.first.costUsd, equals(0.0));
    expect(tracker.totalCost, equals(0.0));
    tracker.dispose();
  });
}
