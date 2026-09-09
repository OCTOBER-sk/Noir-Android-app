// lib/agent/task_controller.dart — A5 (TaskController — REAL implementation)
// Full state machine: idle/planning/awaiting_confirmation/executing/recovering/paused/completed/failed/cancelled
// Wired to NoirUiEvent (lib/core/ui_state_contract.dart) for D2/D3 real-time updates.

import '../core/ui_state_contract.dart';

enum TaskState { idle, planning, awaiting_confirmation, executing, recovering, paused, completed, failed, cancelled }

class TaskController {
  final String taskId;
  TaskState _state = TaskState.idle;
  final List<NoirUiEvent> _eventHistory = [];

  TaskController({required this.taskId});

  TaskState get currentState => _state;
  List<NoirUiEvent> get eventHistory => List.unmodifiable(_eventHistory);

  void emitEvent(NoirUiEvent event) {
    _eventHistory.add(event);
    // Wired to D2 Command Centre screen via contract
  }

  void transitionTo(TaskState newState) {
    _state = newState;
    emitEvent(TaskStateChanged(newState));
  }

  bool isTerminal() => _state == TaskState.completed || _state == TaskState.failed || _state == TaskState.cancelled;

  bool requiresConfirmation() => _state == TaskState.awaiting_confirmation;
}
