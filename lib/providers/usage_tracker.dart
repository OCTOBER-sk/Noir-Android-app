import 'dart:async';

import 'llm_provider.dart';

/// In-memory usage tracker, ready to be backed by a DB later.
///
/// Records every [Usage] snapshot and broadcasts updates to listeners.
class UsageTracker {
  final List<Usage> _entries = [];
  final StreamController<List<Usage>> _controller =
      StreamController<List<Usage>>.broadcast();

  /// Records a [Usage] snapshot and notifies listeners.
  void recordUsage(Usage usage) {
    _entries.add(usage);
    _controller.add(_entries);
  }

  /// Returns an unmodifiable view of all recorded usage entries.
  List<Usage> get entries => List.unmodifiable(_entries);

  /// Total cost in USD across all recorded entries.
  double get totalCost =>
      _entries.fold<double>(0.0, (sum, e) => sum + e.costUsd);

  /// Broadcast stream of the full entries list, emitted on each update.
  Stream<List<Usage>> get onUpdated => _controller.stream;

  /// Releases the internal stream controller.
  void dispose() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}
