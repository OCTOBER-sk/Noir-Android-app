// lib/agent/task_controller.dart — A5 (TaskController core states)
// States: idle | planning | awaiting_confirmation | executing | recovering | paused | completed | failed | cancelled
enum TaskState { idle, planning, awaiting_confirmation, executing, recovering, paused, completed, failed, cancelled }
class TaskController {
  TaskState currentState = TaskState.idle;
  final String currentTaskId;
  TaskController(this.currentTaskId);
  void transitionTo(TaskState newState) => currentState = newState;
}
