// lib/ui/operations_sheet.dart — the app's operations surface.
//
// Before the composition root existed, three screens in lib/ (the live task
// timeline, the usage dashboard and the automation registry) were fully written,
// fully tested, and unreachable from the app: each of them takes an injected
// stream, and nothing injected one. They render an explicit "nothing is wired"
// state when their source is null, which is correct but means a user never sees
// them at all.
//
// This sheet is where the real sources arrive. It holds no state of its own
// about the world: every figure, every row and every timeline step comes from a
// stream the composition root built, and every empty state is the screen's own
// honest "I have not been told" rather than a placeholder this file invented.
//
// The one thing it *does* own is the policy gate's confirmation. The gate
// publishes a [PendingConfirmation] and this sheet is the only holder of one, so
// consent is collected here, once, with both answers available and a countdown
// that ends in a refusal. The automation form is disabled outright unless the
// accessibility service is really connected and really allowed to act, which
// is read from the same [NativeBridge] the executor dispatches through.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/agent_wiring.dart';
import '../platform/accessibility_status.dart';
import '../platform/native_bridge.dart';
import 'live_task_view.dart';
import 'skill_manager_screen.dart';
import 'usage_dashboard_screen.dart';

/// The action verbs [RiskClassifier] actually scores.
///
/// These are not a catalogue of things Noir can do; they are the verbs
/// `lib/safety/risk_classifier.dart` reads to decide a risk tier, offered so
/// that what the user asks for and what the classifier judges are the same
/// words. An action outside this list still runs — the classifier's default for
/// an unrecognised action is STANDARD, not SAFE — but nothing is scored as
/// lower risk than the classifier independently decided.
const List<String> kAutomationActions = <String>[
  'tap',
  'navigate',
  'search',
  'read_screen',
  'send',
  'delete',
  'save_fact',
  'draft',
];

/// Tasks, usage, automations and the gate's own confirmation prompt.
class OperationsSheet extends StatefulWidget {
  const OperationsSheet({
    super.key,
    required this.taskTimeline,
    required this.usage,
    required this.skills,
    required this.confirmations,
    required this.onAnswerConfirmation,
    required this.onRun,
    this.bridge,
  });

  /// The A6 pipeline's real stage-by-stage timeline.
  final Stream<TaskTimelineState> taskTimeline;

  /// Real usage figures, with the dashboard's own unknown-figure handling.
  final Stream<UsageState> usage;

  /// The automations the user really registered.
  final Stream<SkillListState> skills;

  /// Confirmations the policy gate is waiting on.
  final Stream<PendingConfirmation> confirmations;

  /// Answers one. Both answers are always offered; neither is the default.
  final void Function(PendingConfirmation confirmation, bool approved)
  onAnswerConfirmation;

  /// Runs one user-requested action through the A6 pipeline.
  final Future<void> Function(AutomationRequest request) onRun;

  /// The accessibility bridge. Null uses [NativeBridge.instance], which is what
  /// the shipped app passes.
  final NativeBridge? bridge;

  @override
  State<OperationsSheet> createState() => _OperationsSheetState();
}

class _OperationsSheetState extends State<OperationsSheet> {
  late AccessibilityStatusController _status;
  final TextEditingController _input = TextEditingController();
  final TextEditingController _nodeIndex = TextEditingController();

  String _action = kAutomationActions.first;
  StreamSubscription<PendingConfirmation>? _confirmationSubscription;
  PendingConfirmation? _pending;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _status = AccessibilityStatusController(bridge: widget.bridge)
      ..addListener(_onStatusChanged);
    unawaited(_status.refresh());
    _bindConfirmations();
  }

  @override
  void didUpdateWidget(OperationsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.confirmations != widget.confirmations) {
      _bindConfirmations();
    }
    if (oldWidget.bridge != widget.bridge) {
      _status
        ..removeListener(_onStatusChanged)
        ..dispose();
      _status = AccessibilityStatusController(bridge: widget.bridge)
        ..addListener(_onStatusChanged);
      unawaited(_status.refresh());
    }
  }

  @override
  void dispose() {
    _confirmationSubscription?.cancel();
    _status
      ..removeListener(_onStatusChanged)
      ..dispose();
    _input.dispose();
    _nodeIndex.dispose();
    super.dispose();
  }

  void _onStatusChanged() {
    if (mounted) setState(() {});
  }

  void _bindConfirmations() {
    _confirmationSubscription?.cancel();
    final PendingConfirmation? stale = _pending;
    // A confirmation that is replaced by a newer request is a refusal, not a
    // silent drop: the older one can no longer be answered.
    stale?.answer(false);
    _pending = null;
    _confirmationSubscription = widget.confirmations.listen(
      (PendingConfirmation confirmation) {
        if (!mounted) return;
        setState(() => _pending = confirmation);
      },
      onError: (Object _) {
        // The gate's stream does not fail; if it ever did, the honest state is
        // "no confirmation is outstanding", which is what this restores.
        if (mounted) setState(() => _pending = null);
      },
    );
  }

  /// Whether a run may be started at all.
  ///
  /// Read from the platform, not assumed: an accessibility service that is
  /// disconnected, or connected but not allowed to dispatch, leaves the control
  /// disabled and says which of the two it is.
  bool get canAct => _status.status.canDispatchGesture;

  Future<void> _run() async {
    final String input = _input.text.trim();
    if (input.isEmpty || _running || !canAct) return;
    final int? index = int.tryParse(_nodeIndex.text.trim());
    setState(() => _running = true);
    try {
      await widget.onRun(
        AutomationRequest(
          action: _action,
          input: input,
          targetNodeIndex: index != null && index >= 0 ? index : null,
        ),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
        foregroundColor: const Color(0xFFFFFFFF),
        elevation: 0,
        title: const Text(
          'NOIr',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: 5,
          ),
        ),
      ),
      body: SafeArea(
        // A single scroll view rather than a lazy list: the sheet is a fixed,
        // known set of panels, and building them all means each screen's own
        // scroll behaviour composes instead of fighting a lazy parent.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_pending != null) ...[
                _ConfirmationPrompt(
                  confirmation: _pending!,
                  onAnswer: (bool approved) {
                    final PendingConfirmation? outstanding = _pending;
                    if (outstanding == null) return;
                    widget.onAnswerConfirmation(outstanding, approved);
                    if (mounted) setState(() => _pending = null);
                  },
                ),
                const SizedBox(height: 20),
              ],
              _SectionTitle(
                'Run an action',
                subtitle: canAct
                    ? 'The accessibility service is connected and may act.'
                    : '${_status.status.headline}. ${_status.status.remedy ?? ''}'
                          .trim(),
              ),
              const SizedBox(height: 10),
              _ActionForm(
                actions: kAutomationActions,
                selected: _action,
                onActionChanged: (String value) =>
                    setState(() => _action = value),
                input: _input,
                nodeIndex: _nodeIndex,
                enabled: canAct && !_running,
                onRun: canAct ? _run : null,
                busy: _running,
              ),
              const SizedBox(height: 28),
              const _SectionTitle(
                'Live task',
                subtitle: 'Stages the A6 pipeline actually reported',
              ),
              const SizedBox(height: 10),
              _Embedded(source: LiveTaskView(source: widget.taskTimeline)),
              const SizedBox(height: 28),
              const _SectionTitle(
                'Usage',
                subtitle: 'What the provider and the durable history reported',
              ),
              const SizedBox(height: 10),
              _Embedded(source: UsageDashboardScreen(source: widget.usage)),
              const SizedBox(height: 28),
              const _SectionTitle(
                'Automations',
                subtitle: 'Scheduled work you registered, in its real state',
              ),
              const SizedBox(height: 10),
              _Embedded(
                source: SkillManagerScreen(
                  source: widget.skills,
                  now: DateTime.now,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A full screen embedded in the sheet's list.
///
/// The three screens are `Scaffold`s, and a `Scaffold` laid out directly as a
/// `ListView` child is given an unbounded height and throws. Bounding it keeps
/// each screen's own layout intact and gives the sheet a fixed-height panel that
/// scrolls with the rest of the page. The height is generous enough for a
/// timeline and small enough that three of them do not turn the sheet into one
/// very long scroll.
class _Embedded extends StatelessWidget {
  const _Embedded({required this.source});

  static const double height = 360;

  final Widget source;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRRect(borderRadius: BorderRadius.circular(12), child: source),
    );
  }
}

/// The gate's outstanding question, with both answers and no default.
///
/// Nothing here is styled as a recommendation: a user who does nothing reaches
/// the same refusal the timeout produces, which is the point.
class _ConfirmationPrompt extends StatelessWidget {
  const _ConfirmationPrompt({
    required this.confirmation,
    required this.onAnswer,
  });

  final PendingConfirmation confirmation;
  final void Function(bool approved) onAnswer;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Confirmation required',
            style: TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            confirmation.message,
            style: const TextStyle(
              color: Color(0xFFB0B0B0),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Risk level ${confirmation.riskLevel}'
            '${confirmation.needsBiometric ? ', biometric required' : ''}'
            '${confirmation.isAnswered ? '' : ' — unanswered requests expire'}',
            style: const TextStyle(color: Color(0xFF5A5A5A), fontSize: 11),
          ),
          if (!confirmation.canBeApproved) ...[
            const SizedBox(height: 10),
            const Text(
              'This action needs a biometric check. Noir has no biometric '
              'binding in this build, so it cannot be approved here and will '
              'not be attempted.',
              style: TextStyle(
                color: Color(0xFF8A6A3A),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onAnswer(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFB0B0B0),
                    side: const BorderSide(color: Color(0xFF2A2A2A)),
                  ),
                  child: const Text('Deny'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  // Inert for a biometric-demanding action. A control that
                  // looks live and cannot be is the most expensive lie in a
                  // consent prompt.
                  onPressed: confirmation.canBeApproved
                      ? () => onAnswer(true)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE5E5E5),
                    foregroundColor: const Color(0xFF000000),
                    disabledBackgroundColor: const Color(0xFF161616),
                    disabledForegroundColor: const Color(0xFF4A4A4A),
                  ),
                  child: const Text('Allow once'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionForm extends StatelessWidget {
  const _ActionForm({
    required this.actions,
    required this.selected,
    required this.onActionChanged,
    required this.input,
    required this.nodeIndex,
    required this.enabled,
    required this.onRun,
    required this.busy,
  });

  final List<String> actions;
  final String selected;
  final void Function(String value) onActionChanged;
  final TextEditingController input;
  final TextEditingController nodeIndex;
  final bool enabled;
  final Future<void> Function()? onRun;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1A1A1A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String action in actions)
                ChoiceChip(
                  label: Text(action),
                  selected: action == selected,
                  onSelected: enabled
                      ? (bool _) => onActionChanged(action)
                      : null,
                  labelStyle: const TextStyle(
                    color: Color(0xFFB0B0B0),
                    fontSize: 12,
                  ),
                  selectedColor: const Color(0xFF2A2A2A),
                  backgroundColor: const Color(0xFF121212),
                  side: const BorderSide(color: Color(0xFF1A1A1A)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: input,
            enabled: enabled,
            style: const TextStyle(color: Color(0xFFE5E5E5), fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Target text on the current screen',
              labelStyle: TextStyle(color: Color(0xFF5A5A5A), fontSize: 12),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF1A1A1A)),
              ),
              disabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF141414)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: nodeIndex,
            enabled: enabled,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Color(0xFFE5E5E5), fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Node index (optional — blank matches on text)',
              labelStyle: TextStyle(color: Color(0xFF5A5A5A), fontSize: 12),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF1A1A1A)),
              ),
              disabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF141414)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: enabled && onRun != null ? () => onRun!() : null,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE5E5E5),
                foregroundColor: const Color(0xFF000000),
                disabledBackgroundColor: const Color(0xFF161616),
                disabledForegroundColor: const Color(0xFF4A4A4A),
              ),
              child: Text(busy ? 'Running…' : 'Request this action'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFE5E5E5),
            fontSize: 16,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.2,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: const TextStyle(
              color: Color(0xFF888888),
              fontSize: 12,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ],
    );
  }
}
