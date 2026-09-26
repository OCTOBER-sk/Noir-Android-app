// test/ui/fake_state_source.dart — a deterministic stand-in for a state stream.
//
// This is not a fake backend: it has no networking, no timers and no canned
// responses. It is a plain broadcast stream a test pushes into by hand, so
// every screen assertion depends only on the values the test itself wrote.
import 'dart:async';

/// A stream the test owns end to end.
///
/// Nothing is emitted until [emit] is called, so "loading" is a real state the
/// screen genuinely sits in rather than a timing accident.
///
/// Closing: a widget-test body runs inside the binding's fake-async zone, so a
/// body may end the stream (`unawaited(source.close())` plus a pump) but should
/// not await that future — the `done` event is delivered by the next pump. And
/// [close] must not be awaited from a teardown once the body has already closed
/// the stream: awaiting an already-completed future there never resumes.
/// Register `addTearDown(source.close)` only for sources the body never closes.
class FakeStateSource<T> {
  final StreamController<T> _controller = StreamController<T>.broadcast();

  Stream<T> get stream => _controller.stream;

  /// Pushes one state. Delivery is asynchronous, so a test has to pump.
  void emit(T state) => _controller.add(state);

  /// Fails the stream instead of ending it, so the screen's error path is
  /// exercised the way a real source failure would exercise it.
  void fail(Object error) => _controller.addError(error);

  /// Ends the stream, which is a real `onDone` for whoever is listening.
  Future<void> close() => _controller.close();
}
