import 'dart:async';

/// Core task lifecycle states (V2.1 §7 A5).
enum TaskState {
  /// No task is active.
  idle,

  /// Planning the steps for the current goal.
  planning,

  /// Waiting for user confirmation before execution.
  awaitingConfirmation,

  /// Actively executing planned steps.
  executing,

  /// Recovering from a failure during execution.
  recovering,

  /// Execution is paused.
  paused,

  /// Task has reached a terminal outcome.
  terminal,
}

/// Terminal outcome for a task.
enum TaskOutcome {
  /// Task completed successfully.
  completed,

  /// Task failed.
  failed,

  /// Task was cancelled.
  cancelled,
}

/// Minimal task controller driving the simplified state machine (V2.1 §7 A5).
///
/// Events are broadcast as `"prev->next"` tags such as `"idle->planning"`.
class TaskController {
  /// Current lifecycle state.
  TaskState state;

  /// Active task identifier, if any.
  String? activeTaskId;

  /// When the current task was started.
  DateTime? startedAt;

  /// When the current task entered the terminal state.
  DateTime? endedAt;

  /// Terminal outcome, set when [state] is [TaskState.terminal].
  TaskOutcome? outcome;

  final StreamController<String> _controller;

  TaskController._(this._controller)
      : state = TaskState.idle,
        activeTaskId = null,
        startedAt = null,
        endedAt = null,
        outcome = null;

  /// Creates a [TaskController] wired to a broadcast event stream.
  factory TaskController() {
    final c = StreamController<String>.broadcast();
    return TaskController._(c);
  }

  /// Broadcast stream of state-transition tags.
  Stream<String> get events => _controller.stream;

  /// Starts a new task for [goal] with the given [steps].
  ///
  /// Transitions `idle -> planning` and records [activeTaskId] and
  /// [startedAt]. Emits `"idle->planning"` (or the actual previous state
  /// name) on [events].
  Future<void> startTask(String goal, List<String> steps) async {
    final prev = state;
    state = TaskState.planning;
    activeTaskId = goal;
    startedAt = DateTime.now();
    _controller.add('${prev.name}->${state.name}');
  }

  /// Returns [message] if the controller is awaiting confirmation.
  ///
  /// Throws a [StateError] if [state] is not [TaskState.awaitingConfirmation].
  Future<String> requestConfirmation(String message) async {
    if (state != TaskState.awaitingConfirmation) {
      throw StateError(
        'requestConfirmation requires state awaitingConfirmation, was $state',
      );
    }
    return message;
  }

  /// Confirms the pending task.
  ///
  /// Transitions `awaitingConfirmation -> executing` and emits the transition.
  /// Throws [StateError] if not in [TaskState.awaitingConfirmation].
  Future<void> confirmTask() async {
    if (state != TaskState.awaitingConfirmation) {
      throw StateError(
        'confirmTask requires state awaitingConfirmation, was $state',
      );
    }
    final prev = state;
    state = TaskState.executing;
    _controller.add('${prev.name}->${state.name}');
  }

  /// Pauses the executing task for [reason].
  ///
  /// Transitions `executing -> paused` and emits the transition.
  /// Throws [StateError] if not in [TaskState.executing].
  Future<void> pauseTask(String reason) async {
    if (state != TaskState.executing) {
      throw StateError(
        'pauseTask requires state executing, was $state',
      );
    }
    final prev = state;
    state = TaskState.paused;
    _controller.add('${prev.name}->${state.name}');
  }

  /// Resumes a paused task.
  ///
  /// Transitions `paused -> executing` and emits the transition.
  /// Throws [StateError] if not in [TaskState.paused].
  Future<void> resumeTask() async {
    if (state != TaskState.paused) {
      throw StateError(
        'resumeTask requires state paused, was $state',
      );
    }
    final prev = state;
    state = TaskState.executing;
    _controller.add('${prev.name}->${state.name}');
  }

  /// Moves the task into recovery for [reason].
  ///
  /// Transitions `executing -> recovering` and emits the transition.
  /// Throws [StateError] if not in [TaskState.executing].
  Future<void> recoverTask(String reason) async {
    if (state != TaskState.executing) {
      throw StateError(
        'recoverTask requires state executing, was $state',
      );
    }
    final prev = state;
    state = TaskState.recovering;
    _controller.add('${prev.name}->${state.name}');
  }

  /// Completes the task with [outcome].
  ///
  /// Sets [state] to [TaskState.terminal], records [outcome] and [endedAt],
  /// and emits the transition on [events].
  Future<void> completeTask(TaskOutcome outcome) async {
    final prev = state;
    state = TaskState.terminal;
    this.outcome = outcome;
    endedAt = DateTime.now();
    _controller.add('${prev.name}->${state.name}');
  }

  /// Closes the underlying broadcast controller.
  void dispose() {
    _controller.close();
  }
}
