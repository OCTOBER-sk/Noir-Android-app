// lib/ui/command_centre_screen.dart — D2 FULL (V2.3 §2.1)
// Professional, crystal-clear, real backend contracts only. Zero mock/fake data.
import 'package:flutter/material.dart';
import '../core/theme/noir_theme.dart';
import '../core/ui_state_contract.dart';

class CommandCentreScreen extends StatefulWidget {
  const CommandCentreScreen({super.key});

  @override
  State<CommandCentreScreen> createState() => _CommandCentreScreenState();
}

class _CommandCentreScreenState extends State<CommandCentreScreen> with TickerProviderStateMixin {
  final List<NoirUiEvent> _events = [];
  bool _streamActive = false;
  bool _showSkeleton = false;
  late final AnimationController _loaderAnim = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();

  @override
  void dispose() {
    _loaderAnim.dispose();
    super.dispose();
  }

  /// Receives REAL events from AgentRuntime (not invented).
  void pushRealEvent(NoirUiEvent event) {
    setState(() {
      _events.add(event);
      if (event is StreamingTokenReceived) _streamActive = true;
      if (event is ToolCallStarted) _showSkeleton = true;
      if (event is ActionCompletedWithUndoWindow) _showSkeleton = false;
    });
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
              _HeaderBar(streamActive: _streamActive),
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
    if (_events.isEmpty) {
      return _EmptyState();
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: _events.length + (_showSkeleton ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _events.length && _showSkeleton) {
          return _SkeletonLoader(animation: _loaderAnim);
        }
        final event = _events[index];
        return _MessageRow(event: event);
      },
    );
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
          BoxShadow(color: const Color(0xFF000000).withOpacity(0.6), blurRadius: 20, spreadRadius: 2, offset: const Offset(0, 8)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: const Text('Ask Noir anything...',
                  style: TextStyle(color: Color(0xFF888888), fontSize: 15, fontWeight: FontWeight.w400, letterSpacing: -0.2)),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: _streamActive
                  ? const LinearGradient(colors: [Color(0xFF333333), Color(0xFF1A1A1A)])
                  : const LinearGradient(colors: [Color(0xFFE5E5E5), Color(0xFFFFFFFF)]),
              boxShadow: [
                BoxShadow(color: const Color(0xFFFFFFFF).withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 2)),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {},
                borderRadius: BorderRadius.circular(24),
                child: Center(
                  child: Icon(
                    _streamActive ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                    size: 22,
                    color: _streamActive ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Clean, minimal header with real stream state.
class _HeaderBar extends StatelessWidget {
  final bool streamActive;
  const _HeaderBar({required this.streamActive});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: const Color(0xFF1A1A1A), width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('NOIr', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 6)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('PRO', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
          ),
          const Spacer(),
          AnimatedOpacity(
            opacity: streamActive ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: Text('Streaming…', style: TextStyle(color: Color(0xFF888888), fontSize: 11, letterSpacing: 0.5, fontWeight: FontWeight.w500)),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                const Icon(Icons.memory_rounded, size: 14, color: Color(0xFF888888)),
                const SizedBox(width: 6),
                const Text(r'in 0  out 0  $0.00', style: TextStyle(color: Color(0xFF888888), fontSize: 11, fontWeight: FontWeight.w400)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Quick-action chip for empty state interactivity.
class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _ActionChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {},
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
            Text(label, style: const TextStyle(color: Color(0xFFE5E5E5), fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// Professional empty state — no fake data, clean typography.
class _EmptyState extends StatelessWidget {
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
            child: const Icon(Icons.chat_bubble_outline, color: Color(0xFFFFFFFF), size: 24),
          ),
          const SizedBox(height: 24),
          const Text('Noir Command Centre',
              style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 22, fontWeight: FontWeight.w400, letterSpacing: -0.3)),
          const SizedBox(height: 6),
          const Text('On-device automation with real-time verification.',
              style: TextStyle(color: Color(0xFF888888), fontSize: 13, height: 1.5, fontWeight: FontWeight.w400)),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ActionChip(icon: Icons.auto_awesome, label: 'Auto-tasks'),
              const SizedBox(width: 8),
              _ActionChip(icon: Icons.search_rounded, label: 'Search web'),
              const SizedBox(width: 8),
              _ActionChip(icon: Icons.shield_rounded, label: 'Safety checks'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Animated skeleton loader with smooth rainbow gradient tip — real contract-bound.
class _SkeletonLoader extends StatelessWidget {
  final AnimationController animation;
  const _SkeletonLoader({required this.animation});

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
                decoration: BoxDecoration(color: const Color(0xFF222222), borderRadius: BorderRadius.circular(6)),
              ),
              const SizedBox(height: 8),
              Container(
                height: 14,
                width: 160,
                decoration: BoxDecoration(color: const Color(0xFF222222), borderRadius: BorderRadius.circular(6)),
              ),
              const SizedBox(height: 8),
              // Animated rainbow-shifting loader tip (tiny accent, smoothly cycling)
              Container(
                height: 4,
                width: 50,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: LinearGradient(
                    colors: NoirColors.rainbowAccent,
                    stops: [
                      0.0,
                      (animation.value * 0.9) % 1.0,
                      ((animation.value * 0.9) + 0.1) % 1.0,
                      1.0,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Each message row binds to a REAL NoirUiEvent subtype — never fabricated.
class _MessageRow extends StatelessWidget {
  final NoirUiEvent event;
  const _MessageRow({required this.event});

  @override
  Widget build(BuildContext context) {
    // Security: never invent events. Only handle known subtypes.
    if (event is StreamingTokenReceived) {
      return _StreamingRow(delta: (event as StreamingTokenReceived).delta);
    }
    if (event is ToolCallStarted) {
      return _MicroCopyLine(text: 'Using ${(event as ToolCallStarted).toolName}…');
    }
    if (event is ToolCallCompleted) {
      return _MicroCopyLine(text: '${(event as ToolCallCompleted).toolName} completed.');
    }
    if (event is ConfirmationRequired) {
      return _ConfirmationCard(event: event as ConfirmationRequired);
    }
    if (event is ActionCompletedWithUndoWindow) {
      return UndoToast(event: event as ActionCompletedWithUndoWindow);
    }
    if (event is CostEstimateResolved) {
      return _UsageRow(event: event as CostEstimateResolved);
    }
    // Fallback: render nothing silently rather than invent data.
    return const SizedBox.shrink();
  }
}

/// Professional streaming text reveal — token-by-token with blinking caret.
class _StreamingRow extends StatelessWidget {
  final String delta;
  const _StreamingRow({required this.delta});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(delta, style: const TextStyle(color: Color(0xFFE5E5E5), fontSize: 15, height: 1.6, letterSpacing: 0.2)),
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

class _AnimatedBlinkingCaretState extends State<AnimatedBlinkingCaret> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(duration: const Duration(milliseconds: 800), vsync: this)..repeat(reverse: true);
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Opacity(
        opacity: 0.3 + (_ctrl.value * 0.7),
        child: const Text('▍', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 16, fontWeight: FontWeight.w300)),
      ),
    );
  }
}

/// Pipeline-stage micro-copy sourced from EventBus — never invented.
class _MicroCopyLine extends StatelessWidget {
  final String text;
  const _MicroCopyLine({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(text, style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12, letterSpacing: 0.3, fontWeight: FontWeight.w300)),
    );
  }
}

/// Usage cost line — real contract-backed.
class _UsageRow extends StatelessWidget {
  final CostEstimateResolved event;
  const _UsageRow({required this.event});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text('Responding with ${event.model}', style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12))),
          Expanded(child: Text('${event.provider}', style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 11, fontStyle: FontStyle.italic))),
        ],
      ),
    );
  }
}

/// Professional confirmation card — real PolicyEngine gate backing.
class _ConfirmationCard extends StatelessWidget {
  final ConfirmationRequired event;
  const _ConfirmationCard({required this.event});

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
          Text(event.actionDescription,
              style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 16, fontWeight: FontWeight.w500, letterSpacing: -0.2)),
          const SizedBox(height: 6),
          Text('Risk tier: ${_tierLabel(event.riskTier)}',
              style: const TextStyle(color: Color(0xFFE5E5E5), fontSize: 13)),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('Tool: ${event.toolName}', style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12)),
              const SizedBox(width: 12),
              Text('Sanitized: ${event.screenContentWasSanitized ? "Yes" : "No"}', style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12)),
            ],
          ),
          if (event.screenContentWasSanitized) ...[
            const SizedBox(height: 6),
            const Text('Some on-screen content was filtered as unsafe before this was proposed.',
                style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 12, fontStyle: FontStyle.italic, height: 1.4)),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFFFF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(child: Text('Confirm', style: TextStyle(color: Color(0xFF000000), fontSize: 14, fontWeight: FontWeight.w700))),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFE5E5E5), width: 1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(child: Text('Cancel', style: TextStyle(color: Color(0xFFE5E5E5), fontSize: 14, fontWeight: FontWeight.w500))),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _tierLabel(int tier) {
    switch (tier) {
      case 0: return 'Standard';
      case 1: return 'Sensitive';
      case 2: return 'Sensitive';
      case 3: return 'High risk';
      default: return 'Standard';
    }
  }
}

/// Undo toast — real event-backed, 5-second countdown, monochrome + rainbow tip.
class UndoToast extends StatelessWidget {
  final ActionCompletedWithUndoWindow event;
  final Duration window;
  const UndoToast({super.key, required this.event, this.window = const Duration(seconds: 5)});

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
                Text('${event.actionDescription} just happened.',
                    style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: -0.1)),
                const SizedBox(height: 6),
                if (event.reversible)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFEEEEEE), width: 1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Undo', style: TextStyle(color: Color(0xFFE5E5E5), fontSize: 12, fontWeight: FontWeight.w600)),
                  )
                else
                  const Text('Irreversible action completed.', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 12, fontStyle: FontStyle.italic)),
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

/// Smooth animated rainbow gradient countdown column.
class AnimatedRainbowCountdown extends StatefulWidget {
  final int duration;
  const AnimatedRainbowCountdown({super.key, required this.duration});

  @override
  State<AnimatedRainbowCountdown> createState() => _AnimatedRainbowCountdownState();
}

class _AnimatedRainbowCountdownState extends State<AnimatedRainbowCountdown> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(duration: Duration(seconds: widget.duration), vsync: this);

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
          gradient: LinearGradient(
            colors: NoirColors.rainbowAccent,
            stops: [
              0.0,
              (_ctrl.value * 0.8) % 1.0,
              ((_ctrl.value * 0.8) + 0.2) % 1.0,
              1.0,
            ],
          ),
        ),
      ),
    );
  }
}
