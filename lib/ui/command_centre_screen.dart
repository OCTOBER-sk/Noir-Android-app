// lib/ui/command_centre_screen.dart — D2 FULL (V2.3 §2.1)
// Professional, crystal-clear, real backend contracts only. Zero mock/fake data.
//
// Lifecycle: the screen owns a ConversationController (unless one is injected),
// subscribes to its event stream, renders controller state as messages, drives
// the injected assistant backend's delta stream, and routes every visible
// control to a real handler or an explicitly disabled state.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/agent_wiring.dart';
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
    this.events,
    this.confirmations,
    this.onAnswerConfirmation,
    this.onOpenSettings,
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

  /// The real A5/A6 event bus: streaming tokens, tool calls, confirmation
  /// requests, undo windows and every other `NoirUiEvent` the graph emits.
  ///
  /// This parameter exists because the screen's whole event-driven half — the
  /// streaming row, the confirmation card, the undo toast, the skeleton loader
  /// — had exactly one entry point, `pushRealEvent`, and that method had no
  /// caller anywhere in `lib/` or `test/`. It also sat on a library-private
  /// `State`, so no code outside this file could call it. The event renderer was
  /// unreachable by construction, which is why the graph could emit real events
  /// and the screen still showed none of them.
  ///
  /// Null means no event source is connected, and the screen says so through the
  /// states it already has rather than pretending to be live.
  final Stream<NoirUiEvent>? events;

  /// The policy gate's live confirmation requests — the same
  /// `composition.confirmations` stream `OperationsSheet` is already given, and
  /// the same `gate.requests` that `runAutomation` mirrors into the
  /// `ConfirmationRequired` this screen prints as a card.
  ///
  /// A `ConfirmationRequired` event carries the action, the risk tier and the
  /// provenance flag, but not the `PendingConfirmation` that can actually be
  /// answered. Without this stream the card is a description of a request whose
  /// only real answer lives on another screen, which is what made the card's own
  /// controls inert.
  ///
  /// Null means no gate is connected to this screen, and the card says so rather
  /// than rendering a handler that would go nowhere.
  final Stream<PendingConfirmation>? confirmations;

  /// Answers one outstanding request. This is the whole consent path, and the
  /// only call that can approve a gated action: `main.dart` installs a handler
  /// that forwards to `PendingConfirmation.answer`.
  ///
  /// Null means nothing is connected. A null handler must never be replaced by a
  /// local one — a fabricated handler would be a consent path with no gate behind
  /// it — so the card keeps its explicitly disabled rendering and says where the
  /// request is answered instead.
  final void Function(PendingConfirmation confirmation, bool approved)?
  onAnswerConfirmation;

  /// Opens the screen where a provider, its base URL and its API key are
  /// configured. Null renders no settings control, rather than a button that
  /// goes nowhere.
  ///
  /// This is the only way a real user can reach [SettingsRepository.setSecret],
  /// and therefore the only way the app can acquire a provider at all.
  final VoidCallback? onOpenSettings;

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

  /// The gate's confirmation requests. Deliberately its own field, not [_events]:
  /// that one is the conversation controller's stream and [_bindEvents] uses
  /// [_busEvents] for the same reason.
  StreamSubscription<PendingConfirmation>? _confirmations;

  /// The one request the gate is still waiting on, while it is waiting on one.
  PendingConfirmation? _pending;

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
    _bindEvents(widget.events);
    _bindConfirmations();
  }

  /// Subscription to the injected real event bus.
  ///
  /// Deliberately NOT [_events]: that field holds the conversation controller's
  /// own event stream, bound by [_bindController]. Sharing one field for two
  /// independent subscriptions meant `initState` bound the controller and then
  /// cancelled and overwrote it here, leaving the conversation stream dead so
  /// assistant text never reached the timeline.
  StreamSubscription<NoirUiEvent>? _busEvents;

  /// Subscribes to the real event bus and drives the event-driven half of the
  /// screen through [pushRealEvent], which is what it was always written for.
  void _bindEvents(Stream<NoirUiEvent>? events) {
    unawaited(_busEvents?.cancel());
    _busEvents = null;
    if (events == null) return;
    _busEvents = events.listen(pushRealEvent);
  }

  /// Subscribes to the policy gate's requests and holds the outstanding one.
  ///
  /// Same rule as `_OperationsSheetState._bindConfirmations`: a request this
  /// screen stops showing has been superseded, and a superseded request is a
  /// refusal rather than a silent drop. Answering it is safe to do from two
  /// holders at once because `PendingConfirmation.answer` is first-answer-wins
  /// and returns false once anything has answered — a stale refusal here cannot
  /// cancel a request the Operations sheet is legitimately showing.
  void _bindConfirmations() {
    unawaited(_confirmations?.cancel());
    _confirmations = null;
    final PendingConfirmation? stale = _pending;
    _pending = null;
    stale?.answer(false);
    final Stream<PendingConfirmation>? source = widget.confirmations;
    if (source == null) return;
    _confirmations = source.listen(
      (PendingConfirmation confirmation) {
        if (!mounted) return;
        setState(() => _pending = confirmation);
      },
      onError: (Object _) {
        // The gate's stream does not fail. If it ever did, the honest state is
        // "no request is outstanding", which is what this restores.
        if (mounted) setState(() => _pending = null);
      },
    );
  }

  @override
  void didUpdateWidget(CommandCentreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bridge, widget.bridge)) {
      _unbindAccessibility();
      _bindAccessibility(widget.bridge);
    }
    if (!identical(oldWidget.events, widget.events)) {
      _bindEvents(widget.events);
    }
    if (!identical(oldWidget.confirmations, widget.confirmations)) {
      _bindConfirmations();
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
    unawaited(_busEvents?.cancel());
    _busEvents = null;
    unawaited(_confirmations?.cancel());
    _confirmations = null;
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

  /// Answers the request this screen holds and stops offering it.
  ///
  /// The request itself is only released by the injected handler, which is
  /// `PendingConfirmation.answer` in production. This method never approves
  /// anything by itself and never relaxes the gate; with no handler connected
  /// it does nothing at all, which is why the card renders disabled in that
  /// case.
  void _answerConfirmation(bool approved) {
    final void Function(PendingConfirmation, bool)? handler =
        widget.onAnswerConfirmation;
    final PendingConfirmation? outstanding = _pending;
    if (handler == null || outstanding == null) return;
    handler(outstanding, approved);
    if (mounted) setState(() => _pending = null);
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
      // `ToolCallCompleted` is the event that actually ends a tool call. The
      // undo window is not a substitute for it: `AgentRuntimePipeline` awaits
      // `undoWindow.open(5, ...)` *before* `execute.run(plan)`, so on a real run
      // `ActionCompletedWithUndoWindow` has already arrived by the time the tool
      // starts. Clearing only on that event left the loader spinning for the
      // rest of the session. Both are kept: a completed tool call stops the
      // loader, and the undo window still does too for the paths that never
      // reach a tool.
      if (event is ToolCallCompleted || event is ActionCompletedWithUndoWindow) {
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
                onOpenSettings: widget.onOpenSettings,
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
          return _SkeletonLoader(
            key: const Key('command-centre-skeleton'),
            animation: _loaderAnim,
          );
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
      // Every confirmation card on the timeline is offered the one outstanding
      // request. Only the first answer reaches the gate — `answer` is
      // first-answer-wins — and a card for a request that is already released
      // renders itself disabled, so a stale row cannot take a decision.
      return _MessageRow(
        event: item.event,
        confirmation: _pending,
        onAnswer: widget.onAnswerConfirmation == null
            ? null
            : _answerConfirmation,
      );
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
    this.onOpenSettings,
  });

  final bool streamActive;
  final String usageLabel;
  final AccessibilityStatus accessibilityStatus;
  final VoidCallback onOpenSafetyCenter;

  /// Null renders no operations control, which is what a screen with nothing
  /// wired behind it should look like.
  final VoidCallback? onOpenOperations;

  /// Null renders no settings control.
  final VoidCallback? onOpenSettings;

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
              if (onOpenSettings != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onOpenSettings,
                  icon: const Icon(
                    Icons.settings_outlined,
                    size: 16,
                    color: Color(0xFF888888),
                  ),
                  tooltip: 'Provider and API key',
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
  const _SkeletonLoader({required this.animation, super.key});

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
  const _MessageRow({
    required this.event,
    required this.confirmation,
    required this.onAnswer,
  });

  final NoirUiEvent event;

  /// The gate's outstanding request, handed to a confirmation card so the card
  /// can offer the answer rather than describe it.
  final PendingConfirmation? confirmation;

  /// Null means no consent path is connected to this screen.
  final void Function(bool approved)? onAnswer;

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
        return _ConfirmationCard(
          event: event,
          confirmation: confirmation,
          onAnswer: onAnswer,
        );
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

/// Confirmation card — the timeline's record of the gate's outstanding request,
/// and where the answer is given.
///
/// This is the screen the user is already looking at when a gated run starts,
/// so both answers are offered here and they reach the same
/// [PendingConfirmation] the Operations sheet would have answered. Two holders
/// of one request is safe: [PendingConfirmation.answer] is first-answer-wins
/// and returns false once anything has answered, and the enabled state below is
/// derived from the request itself rather than left to that guarantee.
class _ConfirmationCard extends StatelessWidget {
  const _ConfirmationCard({
    required this.event,
    required this.confirmation,
    required this.onAnswer,
  });

  final ConfirmationRequired event;

  /// The gate's outstanding request, while one is outstanding. Null means the
  /// gate has published nothing this card could answer.
  final PendingConfirmation? confirmation;

  /// Answers the held request. Null means no consent path is connected to this
  /// screen at all, and the card says so rather than pretending otherwise.
  final void Function(bool approved)? onAnswer;

  /// Whether either answer may be given right now.
  ///
  /// A request the gate has already released — answered by the other holder, or
  /// expired into a refusal — is never answerable here, and neither is anything
  /// at all while [onAnswer] is null.
  ///
  /// This is read from the request on every build, so it is as fresh as the last
  /// rebuild and no fresher: an answer given on the Operations sheet does not
  /// notify this screen, and a real gated run always emits something afterwards
  /// that does. What makes the window harmless is not this getter but
  /// [PendingConfirmation.answer], which returns false once anything has
  /// answered — so a stale card cannot approve, whatever it looks like.
  bool get _answerable =>
      onAnswer != null && confirmation != null && !confirmation!.isAnswered;

  /// What the card can honestly say about this request's consent.
  ///
  /// Every branch is true in both the wired and the unwired build; the previous
  /// copy ("no policy gate is wired to this card yet") was false in both.
  String get _consentNote {
    final PendingConfirmation? pending = confirmation;
    if (pending == null) {
      return onAnswer == null
          ? 'This card cannot answer it. A gated request is answered in '
                'Operations.'
          : 'No confirmation request is outstanding for this card.';
    }
    if (pending.isAnswered) {
      return pending.answerValue == true
          ? 'This request was answered: approved once.'
          : 'This request was answered: refused or expired, so nothing runs.';
    }
    if (!pending.canBeApproved) {
      return 'This needs a biometric check, which this build cannot perform, so '
          'it cannot be confirmed here. Cancel it, or let it expire.';
    }
    return 'Answering here answers the request the policy gate is waiting on.';
  }

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
                child: _CardActionButton(
                  buttonKey: const Key('confirmation-card-confirm'),
                  label: 'Confirm',
                  filled: true,
                  // Inert for a biometric-demanding action: this build has no
                  // biometric binding, so a tap could only ever be a refusal.
                  // A control that looks live and cannot be is the most
                  // expensive lie in a consent prompt.
                  enabled: _answerable && confirmation!.canBeApproved,
                  onTap: _answerable && confirmation!.canBeApproved
                      ? () => onAnswer!(true)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CardActionButton(
                  buttonKey: const Key('confirmation-card-cancel'),
                  label: 'Cancel',
                  filled: false,
                  enabled: _answerable,
                  onTap: _answerable ? () => onAnswer!(false) : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _consentNote,
            style: const TextStyle(
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
///
/// [onTap] null is the disabled state, and it is drawn as one: a control that
/// looks live and cannot be is the most expensive lie in a consent prompt. The
/// live and disabled paints differ only in grey weight, per V2.3 — no accent.
class _CardActionButton extends StatelessWidget {
  const _CardActionButton({
    required this.label,
    required this.filled,
    required this.enabled,
    this.onTap,
    this.buttonKey,
  });

  final String label;

  /// The filled variant (Confirm) and the outline variant (Cancel), as
  /// FRONTEND_PLAN.md specifies for this card.
  final bool filled;

  /// Whether this control can be pressed. False renders the disabled box and
  /// installs no gesture recogniser, so a tap lands on nothing.
  final bool enabled;

  /// The real action. Null whenever [enabled] is false.
  final VoidCallback? onTap;

  /// Identifies the control's semantics node, which is what the button actually
  /// is: the painted box below it carries no gesture of its own.
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: buttonKey,
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? onTap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // Only a live filled button paints a fill; the outline variant keeps
            // the card's own surface behind it, which is why its label stays
            // light. Black-on-transparent is unreadable on this background.
            color: filled && enabled
                ? const Color(0xFFFFFFFF)
                : Colors.transparent,
            border: Border.all(
              color: !enabled
                  ? const Color(0xFF3A3A3A)
                  : filled
                  ? const Color(0xFFFFFFFF)
                  : const Color(0xFFB0B0B0),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: !enabled
                  ? const Color(0xFF5A5A5A)
                  : filled
                  ? const Color(0xFF000000)
                  : const Color(0xFFB0B0B0),
              fontSize: 14,
              fontWeight: filled ? FontWeight.w700 : FontWeight.w500,
            ),
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
