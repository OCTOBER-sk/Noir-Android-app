// lib/core/ui_state_contract.dart — V2.3 Section 3 (Backend <-> Frontend contract)
// Every UI-visible state MUST originate from one of these — no ad-hoc UI state.
sealed class NoirUiEvent {}

// Maps 1:1 to TaskController core states (A5)
class TaskStateChanged extends NoirUiEvent {
  final TaskState state; // idle | planning | awaiting_confirmation | executing | recovering | paused | completed | failed | cancelled
  TaskStateChanged(this.state);
}

// EventBus secondary events (A6 pipeline)
class StreamingTokenReceived extends NoirUiEvent { final String delta; StreamingTokenReceived(this.delta); }
class ToolCallStarted extends NoirUiEvent { final String toolName; final int riskLevel; ToolCallStarted(this.toolName, this.riskLevel); }
class ToolCallCompleted extends NoirUiEvent { final String toolName; final bool success; ToolCallCompleted(this.toolName, this.success); }
class SideConversationOpened extends NoirUiEvent { final String parentMessageId; SideConversationOpened(this.parentMessageId); }

// Policy Engine / Cost Estimator (A6 + A9)
class ConfirmationRequired extends NoirUiEvent {
  final String actionDescription; final int riskTier; final String toolName; final bool screenContentWasSanitized;
  ConfirmationRequired(this.actionDescription, this.riskTier, this.toolName, this.screenContentWasSanitized);
}
class CostEstimateResolved extends NoirUiEvent {
  final String provider; final String model; final int estimatedTokens;
  CostEstimateResolved(this.provider, this.model, this.estimatedTokens);
}

// Undo Window (A6b / D15)
class ActionCompletedWithUndoWindow extends NoirUiEvent {
  final String actionDescription; final bool reversible; final Duration window;
  ActionCompletedWithUndoWindow(this.actionDescription, this.reversible, this.window);
}

// Backend states mapped
class TaskState {
  static const String idle = 'idle';
  static const String planning = 'planning';
  static const String awaitingConfirmation = 'awaiting_confirmation';
  static const String executing = 'executing';
  static const String recovering = 'recovering';
  static const String paused = 'paused';
  static const String completed = 'completed';
  static const String failed = 'failed';
  static const String cancelled = 'cancelled';
}
