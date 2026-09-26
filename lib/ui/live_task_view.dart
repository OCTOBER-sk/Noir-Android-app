// lib/ui/live_task_view.dart — D3 (V2.3 §2.2)
//
// The timeline is a stream of real [TaskTimelineEvent]s. The view used to take
// a `List<String>` and number its rows with a clock it made up ("12:34",
// "12:35", …), which made a fixed list indistinguishable from a task that was
// actually running. Each row now carries the stage, the detail and the moment
// the runtime reported — or says the moment is unknown.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/noir_theme.dart';

/// Where one step of a task stands.
enum TaskPhase {
  queued,
  running,

  /// The runtime is putting the task back on its feet.
  recovering,
  blocked,
  completed,
  failed,
}

String taskPhaseLabel(TaskPhase phase) {
  switch (phase) {
    case TaskPhase.queued:
      return 'queued';
    case TaskPhase.running:
      return 'running';
    case TaskPhase.recovering:
      return 'recovering';
    case TaskPhase.blocked:
      return 'blocked';
    case TaskPhase.completed:
      return 'completed';
    case TaskPhase.failed:
      return 'failed';
  }
}

/// One real step of a running task.
@immutable
class TaskTimelineEvent {
  const TaskTimelineEvent({
    required this.id,
    required this.stage,
    required this.detail,
    this.phase = TaskPhase.running,
    this.occurredAt,
  });

  final String id;

  /// The pipeline stage that produced this step, as the runtime named it.
  final String stage;
  final String detail;
  final TaskPhase phase;

  /// When it happened. Null means the runtime did not say, and the row says so
  /// rather than borrowing a timestamp from its position in the list.
  final DateTime? occurredAt;

  bool get isRecovering => phase == TaskPhase.recovering;
}

sealed class TaskTimelineState {
  const TaskTimelineState();
}

final class TaskTimelineLoading extends TaskTimelineState {
  const TaskTimelineLoading();
}

final class TaskTimelineFailed extends TaskTimelineState {
  const TaskTimelineFailed(this.message);

  final String message;
}

final class TaskTimelineAvailable extends TaskTimelineState {
  const TaskTimelineAvailable(this.events);

  final List<TaskTimelineEvent> events;
}

class LiveTaskView extends StatefulWidget {
  const LiveTaskView({super.key, this.source, this.onRetry});

  /// The real task runtime timeline. Null means nothing is wired, and the view
  /// reports that instead of drawing steps that never ran.
  final Stream<TaskTimelineState>? source;

  /// Handler for the failure state's retry control, or null for no control.
  final VoidCallback? onRetry;

  @override
  State<LiveTaskView> createState() => _LiveTaskViewState();
}

class _LiveTaskViewState extends State<LiveTaskView> {
  StreamSubscription<TaskTimelineState>? _subscription;
  TaskTimelineState? _state;

  @override
  void initState() {
    super.initState();
    _bind(widget.source);
  }

  @override
  void didUpdateWidget(LiveTaskView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.source, widget.source)) {
      return;
    }
    _unbind();
    _bind(widget.source);
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  void _bind(Stream<TaskTimelineState>? source) {
    if (source == null) {
      return;
    }
    _state = const TaskTimelineLoading();
    _subscription = source.listen(
      (TaskTimelineState state) {
        if (mounted) setState(() => _state = state);
      },
      onError: (Object error) {
        if (mounted) setState(() => _state = TaskTimelineFailed('$error'));
      },
    );
  }

  void _unbind() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    _state = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with NOIr branding
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Row(
                children: [
                  const Text(
                    'NOIr',
                    style: TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 5,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        color: Color(0xFF888888),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(
              color: Color(0xFF1A1A1A),
              thickness: 1,
              height: 1,
              indent: 20,
              endIndent: 20,
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final state = _state;
    if (state == null) {
      return const _TimelineNotice(
        title: 'No task timeline source is connected.',
        detail:
            'No steps are shown because no task runtime is wired to this '
            'view.',
      );
    }
    if (state is TaskTimelineLoading) {
      return const _TimelineNotice(
        title: 'Reading the task timeline…',
        detail: 'Waiting for the task runtime to report.',
        busy: true,
      );
    }
    if (state is TaskTimelineFailed) {
      return _TimelineNotice(
        title: state.message,
        detail: 'The timeline could not be read, so no step is shown.',
        retry: widget.onRetry,
      );
    }
    final events = (state as TaskTimelineAvailable).events;
    if (events.isEmpty) {
      return const _TimelineNotice(
        title: 'No task has been started yet.',
        detail: 'The task runtime answered and it has run no steps.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      itemCount: events.length,
      itemBuilder: (context, index) => _TimelineRow(event: events[index]),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.event});

  final TaskTimelineEvent event;

  @override
  Widget build(BuildContext context) {
    final isRecovering = event.isRecovering;
    final occurredAt = event.occurredAt;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isRecovering ? const Color(0xFF1A1A1A) : const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isRecovering
              ? const Color(0xFF2A2A2A)
              : const Color(0xFF151515),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            occurredAt == null ? '--:--:--' : _clock(occurredAt),
            style: TextStyle(
              color: NoirColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        event.stage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFB0B0B0),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      taskPhaseLabel(event.phase),
                      style: TextStyle(
                        color: isRecovering
                            ? const Color(0xFFE5E5E5)
                            : const Color(0xFF5A5A5A),
                        fontSize: 11,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  event.detail,
                  style: TextStyle(
                    color: isRecovering
                        ? const Color(0xFFFFFFFF)
                        : const Color(0xFFE5E5E5),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                  ),
                ),
                if (occurredAt == null) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'time unknown',
                    style: TextStyle(
                      color: Color(0xFF5A5A5A),
                      fontSize: 10,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineNotice extends StatelessWidget {
  const _TimelineNotice({
    required this.title,
    required this.detail,
    this.busy = false,
    this.retry,
  });

  final String title;
  final String detail;
  final bool busy;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    final onRetry = retry;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFE5E5E5),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFF5A5A5A),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: const TextStyle(
              color: Color(0xFF888888),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            _RetryButton(label: 'Retry', onPressed: onRetry),
          ],
        ],
      ),
    );
  }
}

/// A control that is only drawn when it has a real handler behind it.
class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFFB0B0B0),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Local clock reading of a reported moment, to the second.
String _clock(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}
