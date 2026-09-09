// lib/providers/usage_tracker.dart — B3
class UsageTracker {
  int rpmUsed = 0; int tokensUsed = 0;
  void record({required int tokens}) { tokensUsed += tokens; }
}
