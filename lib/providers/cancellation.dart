/// Cooperative cancellation for provider calls.
library;

import 'dart:async';

import 'errors.dart';

/// One-shot cancellation signal shared by a caller and an in-flight request.
///
/// The transport, the stream pump and any retry loop poll or listen to the same
/// token, so cancelling from a UI button stops a request, a stream and a
/// pending backoff with a single call.
class CancellationToken {
  final Completer<void> _completer = Completer<void>();
  final List<void Function()> _listeners = <void Function()>[];

  bool _cancelled = false;
  Object? _reason;

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// The value passed to the first [cancel] call, if any.
  Object? get reason => _reason;

  /// Completes when the token is cancelled. Never completes with an error.
  Future<void> get whenCancelled => _completer.future;

  /// Registers [listener], returning a function that removes it again.
  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Cancels the token. Subsequent calls keep the first reason.
  void cancel([Object? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final List<void Function()> pending = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final void Function() listener in pending) {
      listener();
    }
    if (!_completer.isCompleted) _completer.complete();
  }

  /// Throws [ProviderException.cancelled] when already cancelled.
  void throwIfCancelled() {
    if (_cancelled) throw ProviderException.cancelled(_reason);
  }
}
