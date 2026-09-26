// lib/core/clock.dart
// Injectable time source. Services never call DateTime.now() directly so that
// timestamps, retention and next-run maths are deterministic under test.

abstract interface class Clock {
  /// Current instant, always in UTC.
  DateTime now();
}

/// Production clock.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

/// Test clock. Reads do not advance time on their own — a test decides when
/// the world moves forward, so a suite can assert exact instants.
class FakeClock implements Clock {
  FakeClock(DateTime now, {this.autoAdvance = Duration.zero})
    : _now = now.toUtc();

  DateTime _now;

  /// Optional per-read increment, for code paths that call now() twice and must
  /// still see strictly increasing stamps.
  final Duration autoAdvance;

  @override
  DateTime now() {
    final DateTime current = _now;
    if (autoAdvance > Duration.zero) {
      _now = _now.add(autoAdvance);
    }
    return current;
  }

  void advance(Duration delta) => _now = _now.add(delta);

  void setTo(DateTime instant) => _now = instant.toUtc();
}
