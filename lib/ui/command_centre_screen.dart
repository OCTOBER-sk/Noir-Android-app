// lib/ui/command_centre_screen.dart — D2 FULL (V2.3 §2.1)
// Professional, crystal-clear, real backend contracts only. Zero mock/fake data.
//
// Lifecycle: the screen owns a ConversationController (unless one is injected),
// subscribes to its event stream, renders controller state as messages, drives
// the injected assistant backend's delta stream, and routes every visible
// control to a real handler or an explicitly disabled state.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/conversation_controller.dart';
import '../core/mcp_composition.dart';
import '../core/theme/noir_theme.dart';
import '../core/ui_state_contract.dart';
import '../platform/accessibility_status.dart';
import '../platform/native_bridge.dart';
import '../providers/usage_tracker.dart';
import 'accessibility_status_view.dart';
import 'safety_center_screen.dart';

/// Streams an assistant reply for a submitted prompt onto [controller].
///
/// The responder must call [ConversationController.beginAssistantMessage],
/// then [ConversationController.appendAssistantDelta] for each chunk and
/// [ConversationController.stopActiveStream] when finished. Production wires no
/// responder yet, so the screen reports that nothing was generated instead of
/// inventing a reply. Tests inject a responder to drive the real streaming path.
typedef AssistantResponder =
    void Function(String prompt, ConversationController controller);

/// Produces the assistant's answer to [prompt] as a stream of text deltas.
///
/// The screen owns the conversation: it opens the assistant turn on the injected
/// [ConversationController], appends every delta to it, and closes the turn when
/// the stream ends, errors, or is cancelled. A backend that cannot answer must
/// fail its own stream — quietly returning an empty one would be indistinguishable
/// from a successful reply that said nothing.
typedef AssistantReplyStream = Stream<String> Function(String prompt);

/// One row of the Command Centre timeline, in submission order.
sealed class _TimelineItem {
  const _TimelineItem();
}

class _MessageItem extends _TimelineItem {
  final String messageId;

  const _MessageItem(this.messageId);
}

class _PipelineEventItem extends _TimelineItem {
  final NoirUiEvent event;

  const _PipelineEventItem(this.event);
}

class _SystemNoteItem extends _TimelineItem {
  final String text;

  const _SystemNoteItem(this.text);
}

class CommandCentreScreen extends StatefulWidget {
  const CommandCentreScreen({
    super.key,
    this.controller,
    this.responder,
    this.replyStream,
    this.usage,
    this.bridge,
    this.operations,
    this.mcp,
  });

  /// Injected in tests. Production leaves it null and the screen owns the
  /// controller it creates in [State.initState].
  final ConversationController? controller;

  /// Null means "no assistant backend connected" — never a fabricated reply.
  final AssistantResponder? responder;

  /// The real assistant backend, as a delta stream per prompt. Null (with a null
  /// [responder]) means the same thing it means for [responder]: nothing is
  /// connected, and the screen says so instead of inventing an answer. When both
  /// are supplied the [responder] drives the turn and this stream is ignored.
  final AssistantReplyStream? replyStream;

  /// Null means no usage has been recorded by a tracker yet.
  final UsageTracker? usage;

  /// The accessibility bridge. Null uses the process-wide
  /// [NativeBridge.instance]; tests inject their own so they can mock the
  /// channel. The screen only ever reads status through it — it never touches
  /// a MethodChannel, and it never dispatches a gesture.
  final NativeBridge? bridge;

  /// The app's real operations surface: the live task timeline, the usage
  /// dashboard, the automation registry and the policy gate's own confirmation
  /// prompt. Null renders no control for it at all, rather than a button that
  /// opens an empty sheet.
  final Widget? operations;

  /// What the composition root built for MCP, handed to the Safety Center so
  /// the two never disagree about whether Noir has MCP capability. Null means
  /// the Safety Center says so.
  final McpWiring? mcp;

  @override
  State<CommandCentreScreen> createState() => _CommandCentreScreenState();
}

class _CommandCentreScreenState extends State<CommandCentreScreen>
    with TickerProviderStateMixin {
  static const String _noBackendNote =
      'No assistant backend is connected — nothing was generated.';
  static const String _emptyReplyNote = 'The assistant returned no content.';
  static const String _streamFailedNote = 'The assistant stream failed:';
  static const String _cancelledNote =
      'Cancelled — the assistant stream was stopped.';
  static const String _closedNote =
      'This conversation is closed — nothing was sent.';

  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final List<_TimelineItem> _timeline = <_TimelineItem>[];
  final Set<String> _renderedMessageIds = <String>{};

  late ConversationController _controller;
  late bool _ownsController;
  late AccessibilityStatusController _accessibility;
  StreamSubscription<NoirUiEvent>? _events;

  /// The live subscription to the injected assistant backend, while one is
  /// running. Cancelled on stop, on failure, and on unmount.
  StreamSubscription<String>? _replySubscription;
  bool _showSkeleton = false;
  bool _pipelineStreaming = false;
  late final AnimationController _loaderAnim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void initState() {
    super.initState();
    _bindController(widget.controller, owns: widget.controller == null);
    _bindAccessibility(widget.bridge);
  }

  @override
  void didUpdateWidget(CommandCentreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bridge, widget.bridge)) {
      _unbindAccessibility();
      _bindAccessibility(widget.bridge);
    }
    if (identical(oldWidget.controller, widget.controller)) {
      return;
    }
    // Release the previous binding before adopting the new one, so the
    // subscription stops driving this State and a controller this screen
    // created itself is closed. An injected controller is never closed here:
    // its owner stays responsible for its lifetime.
    _unbindController();
    _timeline.clear();
    _renderedMessageIds.clear();
    _bindController(widget.controller, owns: widget.controller == null);
  }

  @override
  void dispose() {
    _unbindController();
    _unbindAccessibility();
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    _loaderAnim.dispose();
    super.dispose();
  }

  /// Subscribes to the live accessibility status and asks for it immediately.
  /// A failure to answer renders as "service off"; it never throws here.
  void _bindAccessibility(NativeBridge? bridge) {
    _accessibility = AccessibilityStatusController(bridge: bridge)
      ..addListener(_onAccessibilityChanged);
    unawaited(_accessibility.refresh());
  }

  void _unbindAccessibility() {
    _accessibility.removeListener(_onAccessibilityChanged);
    _accessibility.dispose();
  }

  void _onAccessibilityChanged() {
    if (mounted) setState(() {});
  }

  /// Binds [injected] (or a fresh controller when it is null) and subscribes to
  /// its events. [owns] records whether this screen created the controller and
  /// is therefore responsible for closing it.
  void _bindController(ConversationController? injected, {required bool owns}) {
    _controller = injected ?? ConversationController();
    _ownsController = owns;
    _events = _controller.events.listen(_onControllerEvent);
  }

  /// Cancels the event subscription and closes the controller only if this
  /// screen owns it. Safe to call more than once.
  void _unbindController() {
    _cancelReplySubscription();
    final subscription = _events;
    _events = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    if (_ownsController) {
      unawaited(_controller.close());
      _ownsController = false;
    }
  }

  /// Reduces controller events into timeline rows — never invents content.
  void _onControllerEvent(NoirUiEvent event) {
    if (!mounted) {
      return;
    }
    setState(() {
      switch (event) {
        case UserMessageSubmitted(:final messageId):
          _addMessageItem(messageId);
        case AssistantMessageStarted(:final messageId):
          _addMessageItem(messageId);
        default:
          break;
      }
    });
    _scrollToEnd();
  }

  /// Idempotent so a message can be rendered the moment it is submitted,
  /// without the asynchronous event adding a second row for it.
  void _addMessageItem(String messageId) {
    if (!_renderedMessageIds.add(messageId)) {
      return;
    }
    _timeline.add(_MessageItem(messageId));
  }

  /// Receives REAL events from AgentRuntime (not invented).
  void pushRealEvent(NoirUiEvent event) {
    if (!mounted) {
      return;
    }
    setState(() {
      _timeline.add(_PipelineEventItem(event));
      if (event is StreamingTokenReceived) {
        _pipelineStreaming = true;
      }
      if (event is ToolCallStarted) {
        _showSkeleton = true;
      }
      if (event is ActionCompletedWithUndoWindow) {
        _showSkeleton = false;
      }
    });
    _scrollToEnd();
  }

  void _handleActionButton() {
    if (_controller.hasActiveStream) {
      _stopActiveStream();
      return;
    }

    final prompt = _composer.text.trim();
    if (prompt.isEmpty) {
      return;
    }

    if (_controller.isClosed) {
      // The controller can be closed by whoever owns it while this screen is
      // still mounted. Report it rather than letting the submit throw.
      setState(() => _timeline.add(const _SystemNoteItem(_closedNote)));
      return;
    }

    final submitted = _controller.submitUserMessage(prompt);
    _composer.clear();

    final responder = widget.responder;
    final replyStream = widget.replyStream;
    setState(() {
      _addMessageItem(submitted.id);
      if (responder == null && replyStream == null) {
        _timeline.add(const _SystemNoteItem(_noBackendNote));
      }
    });
    if (responder != null) {
      responder(prompt, _controller);
    } else if (replyStream != null) {
      _startReply(prompt, replyStream);
    }
    _scrollToEnd();
  }

  /// Opens an assistant turn and pipes the backend's deltas into it. The
  /// controller stays the single source of truth for the turn's text, so the
  /// timeline cannot drift from what the conversation actually holds.
  void _startReply(String prompt, AssistantReplyStream replyStream) {
    Stream<String> deltas;
    try {
      deltas = replyStream(prompt);
    } on Object catch (error) {
      // A backend that cannot even be asked has failed; say so.
      _failReply(error);
      return;
    }

    final messageId = _controller.beginAssistantMessage();
    _replySubscription = deltas.listen(
      (String delta) {
        if (!mounted) {
          return;
        }
        _controller.appendAssistantDelta(messageId, delta);
      },
      onError: _failReply,
      onDone: () => _completeReply(messageId),
      cancelOnError: true,
    );
  }

  /// A stream that ended on its own. An assistant turn that produced nothing is
  /// reported as such instead of rendering as an empty message.
  void _completeReply(String messageId) {
    _replySubscription = null;
    final message = _controller.messageById(messageId);
    if (_controller.hasActiveStream) {
      _controller.stopActiveStream();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      if (message == null || message.text.trim().isEmpty) {
        _timeline.add(const _SystemNoteItem(_emptyReplyNote));
      }
    });
    _scrollToEnd();
  }

  /// The backend failed. Whatever had genuinely arrived is kept, the turn is
  /// closed, and the reason is spelled out on the timeline.
  void _failReply(Object error) {
    _cancelReplySubscription();
    if (_controller.hasActiveStream) {
      _controller.stopActiveStream();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _timeline.add(_SystemNoteItem('$_streamFailedNote $error'));
    });
    _scrollToEnd();
  }

  /// The user pressed stop. The turn is closed, the backend is detached, and the
  /// timeline says the stream was cancelled rather than quietly going quiet.
  void _stopActiveStream() {
    _cancelReplySubscription();
    if (_controller.hasActiveStream) {
      _controller.stopActiveStream();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _timeline.add(const _SystemNoteItem(_cancelledNote));
    });
    _scrollToEnd();
  }

  void _cancelReplySubscription() {
    final subscription = _replySubscription;
    _replySubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }

  void _prefillComposer(String prompt) {
    _composer
      ..text = prompt
      ..selection = TextSelection.collapsed(offset: prompt.length);
    setState(() {});
    _composerFocus.requestFocus();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Opens the Safety Center, which is where the real accessibility status and
  /// the real A6a screen audit live. The same bridge instance is handed over so
  /// the two screens never disagree about what the service is doing.
  void _openSafetyCenter() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SafetyCenterScreen(bridge: widget.bridge, mcp: widget.mcp),
      ),
    );
  }

  /// Opens the operations surface the composition root injected. The widget is
  /// built once, by the app, so the sheet shows the app's real objects rather
  /// than a copy this screen made of them.
  void _openOperations() {
    final Widget? operations = widget.operations;
    if (operations == null) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => operations));
  }

  String _usageLabel() {
    final usage = widget.usage;
    if (usage == null) {
      return 'Usage idle';
    }
    return 'in ${usage.rpmUsed}  out ${usage.tokensUsed}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF080808), Color(0xFF000000)],
            stops: [0.0, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _HeaderBar(
                streamActive: _controller.hasActiveStream || _pipelineStreaming,
                usageLabel: _usageLabel(),
                accessibilityStatus: _accessibility.status,
                onOpenSafetyCenter: _openSafetyCenter,
                onOpenOperations: widget.operations == null
                    ? null
                    : _openOperations,
              ),
              Expanded(child: _buildMessageArea()),
              const SizedBox(height: 8),
              _buildComposer(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageArea() {
    if (_timeline.isEmpty) {
      return _EmptyState(onSuggestionSelected: _prefillComposer);
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: _timeline.length + (_showSkeleton ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _timeline.length) {
          return _SkeletonLoader(animation: _loaderAnim);
        }
        return _buildTimelineRow(_timeline[index]);
      },
    );
  }

  Widget _buildTimelineRow(_TimelineItem item) {
    if (item is _MessageItem) {
      final message = _controller.messageById(item.messageId);
      if (message == null) {
        return const SizedBox.shrink();
      }
      return _ConversationRow(message: message, loaderAnimation: _loaderAnim);
    }
    if (item is _PipelineEventItem) {
      return _MessageRow(event: item.event);
    }
    if (item is _SystemNoteItem) {
      return _MicroCopyLine(text: item.text);
    }
    return const SizedBox.shrink();
  }

  Widget _buildComposer() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: const Color(0xFF222222), width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.6),
            blurRadius: 20,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: TextField(
                controller: _composer,
                focusNode: _composerFocus,
                onChanged: (_) => setState(() {}),
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                cursorColor: const Color(0xFFB0B0B0),
                style: const TextStyle(
                  color: Color(0xFF888888),
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.2,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: 'Ask Noir anything...',
                  hintStyle: TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildActionButton(),
        ],
      ),
    );
  }

  /// Single real control: stop the active stream, or send the composed prompt.
  /// When neither is possible the button is rendered — and announced — disabled.
  Widget _buildActionButton() {
    final isStop = _controller.hasActiveStream;
    final canAct = isStop || _composer.text.trim().isNotEmpty;
    return Semantics(
      button: true,
      enabled: canAct,
      label: isStop ? 'Stop' : 'Send',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: canAct
              ? isStop
                    ? const LinearGradient(
                        colors: [Color(0xFF333333), Color(0xFF1A1A1A)],
                      )
                    : const LinearGradient(
                        colors: [Color(0xFFE5E5E5), Color(0xFFFFFFFF)],
                      )
              : const LinearGradient(
                  colors: [Color(0xFF1A1A1A), Color(0xFF1A1A1A)],
                ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFFFFFF).withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: canAct ? _handleActionButton : null,
            borderRadius: BorderRadius.circular(24),
            child: Center(
              child: Icon(
                isStop ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                size: 22,
                color: !canAct
                    ? const Color(0xFF4A4A4A)
                    : isStop
                    ? const Color(0xFFFFFFFF)
                    : const Color(0xFF000000),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clean, minimal header with real stream state and the live service status.
class _HeaderBar extends StatelessWidget {
  const _HeaderBar({
    required this.streamActive,
    required this.usageLabel,
    required this.accessibilityStatus,
    required this.onOpenSafetyCenter,
    this.onOpenOperations,
  });

  final bool streamActive;
  final String usageLabel;
  final AccessibilityStatus accessibilityStatus;
  final VoidCallback onOpenSafetyCenter;

  /// Null renders no operations control, which is what a screen with nothing
  /// wired behind it should look like.
  final VoidCallback? onOpenOperations;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: const Color(0xFF1A1A1A), width: 1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'NOIr',
                style: TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'PRO',
                  style: TextStyle(
                    color: Color(0xFFB0B0B0),
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const Spacer(),
              AnimatedOpacity(
                opacity: streamActive ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Text(
                  'Streaming…',
                  style: TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 11,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF161616),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.memory_rounded,
                      size: 14,
                      color: Color(0xFF888888),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      usageLabel,
                      style: const TextStyle(
                        color: Color(0xFF888888),
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // The service status lives on its own line: the row above is already
          // at its width budget on a 360dp phone, and an overflowing header
          // would be a worse regression than a slightly taller one.
          const SizedBox(height: 10),
          Row(
            children: [
              AccessibilityStatusPill(
                status: accessibilityStatus,
                onTap: onOpenSafetyCenter,
              ),
              if (onOpenOperations != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onOpenOperations,
                  icon: const Icon(
                    Icons.tune_rounded,
                    size: 16,
                    color: Color(0xFF888888),
                  ),
                  tooltip: 'Tasks, usage and automations',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  accessibilityStatus.headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF5A5A5A),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Quick-action chip: fills the real composer, never fabricates a prompt run.
class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: const Color(0xFF888888)),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFE5E5E5),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Professional empty state — no fake data, clean typography.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSuggestionSelected});

  final ValueChanged<String> onSuggestionSelected;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.chat_bubble_outline,
              color: Color(0xFFFFFFFF),
              size: 24,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Noir Command Centre',
            style: TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 22,
              fontWeight: FontWeight.w400,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'On-device automation with real-time verification.',
            style: TextStyle(
              color: Color(0xFF888888),
              fontSize: 13,
              height: 1.5,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ActionChip(
                icon: Icons.auto_awesome,
                label: 'Auto-tasks',
                onPressed: () => onSuggestionSelected(
                  'Summarise today\'s automation tasks.',
                ),
              ),
              const SizedBox(width: 8),
              _ActionChip(
                icon: Icons.search_rounded,
                label: 'Search web',
                onPressed: () =>
                    onSuggestionSelected('Search the web for Noir.'),
              ),
              const SizedBox(width: 8),
              _ActionChip(
                icon: Icons.shield_rounded,
                label: 'Safety checks',
                onPressed: () => onSuggestionSelected(
                  'Run the safety checks before acting.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The shared "rainbow-shifting" accent behind the tiny loader tip and the undo
/// countdown.
///
/// The cycle rotates the colour list rather than moving the stops: gradient
/// stops must be non-decreasing, so shifting them modulo 1.0 builds a stop list
/// that does not even match its own colours (7 colours, 4 stops) and throws
/// during paint the first time the loader is ever shown.
LinearGradient _cyclingAccent(Animation<double> animation) {
  const List<Color> colors = NoirColors.rainbowAccent;
  final int step = (animation.value * colors.length).floor() % colors.length;
  return LinearGradient(
    colors: <Color>[
      for (int i = 0; i < colors.length; i++)
        colors[(i + step) % colors.length],
    ],
    stops: <double>[
      for (int i = 0; i < colors.length; i++) i / (colors.length - 1),
    ],
  );
}

/// Animated skeleton loader with smooth rainbow gradient tip — real contract-bound.
class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader({required this.animation});

  final AnimationController animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 14,
                width: 260,
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 14,
                width: 160,
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 8),
              // Animated rainbow-shifting loader tip (tiny accent, smoothly cycling)
              Container(
                height: 4,
                width: 50,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: _cyclingAccent(animation),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Renders one conversation message from controller state only.
class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.message,
    required this.loaderAnimation,
  });

  final ConversationMessage message;
  final AnimationController loaderAnimation;

  @override
  Widget build(BuildContext context) {
    if (message.role == MessageRole.user) {
      return _UserMessageRow(text: message.text);
    }
    if (message.text.isEmpty) {
      if (message.isStreaming) {
        return _SkeletonLoader(animation: loaderAnimation);
      }
      return const _MicroCopyLine(text: 'No content was returned.');
    }
    return _AssistantMessageRow(
      text: message.text,
      isStreaming: message.isStreaming,
    );
  }
}

/// User turn — right-aligned monochrome bubble.
class _UserMessageRow extends StatelessWidget {
  const _UserMessageRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2A2A2A)),
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xFFE5E5E5),
              fontSize: 15,
              height: 1.6,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Assistant turn — streamed text with a blinking caret while tokens arrive.
class _AssistantMessageRow extends StatelessWidget {
  const _AssistantMessageRow({required this.text, required this.isStreaming});

  final String text;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFE5E5E5),
                fontSize: 15,
                height: 1.6,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (isStreaming) const AnimatedBlinkingCaret(),
        ],
      ),
    );
  }
}

/// Each message row binds to a REAL NoirUiEvent subtype — never fabricated.
class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.event});

  final NoirUiEvent event;

  @override
  Widget build(BuildContext context) {
    final event = this.event;
    // Security: never invent events. Only handle known subtypes.
    switch (event) {
      case StreamingTokenReceived(:final delta):
        return _StreamingRow(delta: delta);
      case ToolCallStarted(:final toolName):
        return _MicroCopyLine(text: 'Using $toolName…');
      case ToolCallCompleted(:final toolName):
        return _MicroCopyLine(text: '$toolName completed.');
      case ConfirmationRequired():
        return _ConfirmationCard(event: event);
      case ActionCompletedWithUndoWindow():
        return UndoToast(event: event);
      case CostEstimateResolved():
        return _UsageRow(event: event);
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Professional streaming text reveal — token-by-token with blinking caret.
class _StreamingRow extends StatelessWidget {
  const _StreamingRow({required this.delta});

  final String delta;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              delta,
              style: const TextStyle(
                color: Color(0xFFE5E5E5),
                fontSize: 15,
                height: 1.6,
                letterSpacing: 0.2,
              ),
            ),
          ),
          // Blinking caret — monochrome muted
          const AnimatedBlinkingCaret(),
        ],
      ),
    );
  }
}

/// Subtle monochrome blinking caret — no color urgency.
class AnimatedBlinkingCaret extends StatefulWidget {
  const AnimatedBlinkingCaret({super.key});

  @override
  State<AnimatedBlinkingCaret> createState() => _AnimatedBlinkingCaretState();
}

class _AnimatedBlinkingCaretState extends State<AnimatedBlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    duration: const Duration(milliseconds: 800),
    vsync: this,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Opacity(
        opacity: 0.3 + (_ctrl.value * 0.7),
        child: const Text(
          '▍',
          style: TextStyle(
            color: Color(0xFFB0B0B0),
            fontSize: 16,
            fontWeight: FontWeight.w300,
          ),
        ),
      ),
    );
  }
}

/// Pipeline-stage micro-copy sourced from EventBus — never invented.
class _MicroCopyLine extends StatelessWidget {
  const _MicroCopyLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFB0B0B0),
          fontSize: 12,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w300,
        ),
      ),
    );
  }
}

/// Usage cost line — real contract-backed.
class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.event});

  final CostEstimateResolved event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Responding with ${event.model}',
              style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              event.provider,
              style: const TextStyle(
                color: Color(0xFFB0B0B0),
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Confirmation card — the policy gate is not wired yet, so both controls are
/// rendered explicitly disabled instead of as dead, tappable-looking buttons.
class _ConfirmationCard extends StatelessWidget {
  const _ConfirmationCard({required this.event});

  final ConfirmationRequired event;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            event.actionDescription,
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Risk tier: ${_tierLabel(event.riskTier)}',
            style: const TextStyle(color: Color(0xFFE5E5E5), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                'Tool: ${event.toolName}',
                style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12),
              ),
              const SizedBox(width: 12),
              Text(
                'Sanitized: ${event.screenContentWasSanitized ? 'Yes' : 'No'}',
                style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12),
              ),
            ],
          ),
          if (event.screenContentWasSanitized) ...[
            const SizedBox(height: 6),
            const Text(
              'Some on-screen content was filtered as unsafe before this was proposed.',
              style: TextStyle(
                color: Color(0xFFB0B0B0),
                fontSize: 12,
                fontStyle: FontStyle.italic,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _CardActionButton(label: 'Confirm', filled: true),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CardActionButton(label: 'Cancel', filled: false),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Disabled: no policy gate is wired to this card yet.',
            style: TextStyle(
              color: Color(0xFF5A5A5A),
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  String _tierLabel(int tier) {
    switch (tier) {
      case 0:
        return 'Standard';
      case 1:
        return 'Sensitive';
      case 2:
        return 'Sensitive';
      case 3:
        return 'High risk';
      default:
        return 'Standard';
    }
  }
}

/// Card action that is either wired to a real handler or visibly disabled.
class _CardActionButton extends StatelessWidget {
  const _CardActionButton({required this.label, required this.filled});

  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: false,
      label: label,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: const Color(0xFF3A3A3A), width: 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: const Color(0xFF5A5A5A),
            fontSize: 14,
            fontWeight: filled ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Undo toast — real event-backed, 5-second countdown, monochrome + rainbow tip.
class UndoToast extends StatelessWidget {
  const UndoToast({
    super.key,
    required this.event,
    this.window = const Duration(seconds: 5),
  });

  final ActionCompletedWithUndoWindow event;
  final Duration window;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${event.actionDescription} just happened.',
                  style: const TextStyle(
                    color: Color(0xFFFFFFFF),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 6),
                if (event.reversible)
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _UndoActionButton(),
                      SizedBox(height: 6),
                      Text(
                        'Disabled: undo is not wired to an action executor yet.',
                        style: TextStyle(
                          color: Color(0xFF5A5A5A),
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  )
                else
                  const Text(
                    'Irreversible action completed.',
                    style: TextStyle(
                      color: Color(0xFFB0B0B0),
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
          // Animated rainbow-shifting countdown bar (tiny, smooth)
          AnimatedRainbowCountdown(duration: window.inSeconds),
        ],
      ),
    );
  }
}

/// Undo control — rendered disabled until an action executor is wired.
class _UndoActionButton extends StatelessWidget {
  const _UndoActionButton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: false,
      label: 'Undo',
      child: const SizedBox(
        width: 60,
        height: 28,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.fromBorderSide(BorderSide(color: Color(0xFF3A3A3A))),
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          child: Center(
            child: Text(
              'Undo',
              style: TextStyle(
                color: Color(0xFF5A5A5A),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Smooth animated rainbow gradient countdown column.
class AnimatedRainbowCountdown extends StatefulWidget {
  const AnimatedRainbowCountdown({super.key, required this.duration});

  final int duration;

  @override
  State<AnimatedRainbowCountdown> createState() =>
      _AnimatedRainbowCountdownState();
}

class _AnimatedRainbowCountdownState extends State<AnimatedRainbowCountdown>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    duration: Duration(seconds: widget.duration),
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Container(
        width: 4,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          gradient: _cyclingAccent(_ctrl),
        ),
      ),
    );
  }
}
