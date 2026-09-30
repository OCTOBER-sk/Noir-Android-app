// lib/core/ui_state_contract.dart — V2.3 Section 3 (Backend <-> Frontend contract)
// Every UI-visible state MUST originate from one of these — no ad-hoc UI state.
sealed class NoirUiEvent {
  const NoirUiEvent();
}

// Maps 1:1 to TaskController core states (A5)
class TaskStateChanged extends NoirUiEvent {
  final TaskState
  state; // idle | planning | awaitingConfirmation | executing | recovering | paused | completed | failed | cancelled
  TaskStateChanged(this.state);
}

// EventBus secondary events (A6 pipeline)
class StreamingTokenReceived extends NoirUiEvent {
  final String delta;
  StreamingTokenReceived(this.delta);
}

class ToolCallStarted extends NoirUiEvent {
  final String toolName;
  final int riskLevel;
  ToolCallStarted(this.toolName, this.riskLevel);
}

class ToolCallCompleted extends NoirUiEvent {
  final String toolName;
  final bool success;
  ToolCallCompleted(this.toolName, this.success);
}

class SideConversationOpened extends NoirUiEvent {
  final String parentMessageId;
  SideConversationOpened(this.parentMessageId);
}

// Policy Engine / Cost Estimator (A6 + A9)
class ConfirmationRequired extends NoirUiEvent {
  final String actionDescription;
  final int riskTier;
  final String toolName;
  final bool screenContentWasSanitized;
  ConfirmationRequired(
    this.actionDescription,
    this.riskTier,
    this.toolName,
    this.screenContentWasSanitized,
  );
}

class CostEstimateResolved extends NoirUiEvent {
  final String provider;
  final String model;
  final int estimatedTokens;
  CostEstimateResolved(this.provider, this.model, this.estimatedTokens);
}

// Undo Window (A6b / D15)
//
// `actionId` is the handle the UI hands back when the user presses Undo: it is
// the id of the window that is counting down right now, and it is what
// `NoirComposition.undo` looks the live action up by. Without it the control
// could only be drawn, never pressed.
class ActionCompletedWithUndoWindow extends NoirUiEvent {
  final String actionDescription;
  final bool reversible;
  final Duration window;
  final String actionId;
  const ActionCompletedWithUndoWindow(
    this.actionDescription,
    this.reversible,
    this.window,
    this.actionId,
  );
}

class UserMessageSubmitted extends NoirUiEvent {
  final String messageId;
  final String text;
  const UserMessageSubmitted(this.messageId, this.text);
}

class AssistantMessageStarted extends NoirUiEvent {
  final String messageId;
  const AssistantMessageStarted(this.messageId);
}

class AssistantDeltaReceived extends NoirUiEvent {
  final String messageId;
  final String delta;
  final String aggregatedText;
  const AssistantDeltaReceived(this.messageId, this.delta, this.aggregatedText);
}

class AssistantStreamStopped extends NoirUiEvent {
  final String messageId;
  const AssistantStreamStopped(this.messageId);
}

// Backend states mapped
enum TaskState {
  idle,
  planning,
  awaitingConfirmation,
  executing,
  recovering,
  paused,
  completed,
  failed,
  cancelled,
}
