// lib/ui/usage_dashboard_screen.dart — D6 (V2.3 §2.4)
//
// Every figure on this screen comes from an injected [UsageSnapshot]. There is
// no default dashboard: with no source connected the screen says so, a snapshot
// that reports nothing renders as empty rather than as zeroes, and a source that
// fails renders as a failure. The numbers this file used to hard-code (1,240
// tokens, \$0.00, "12 / 20 req/min", "Noir Engine v2") were fiction presented
// as telemetry, which is the one thing a stats screen must never be.
import 'dart:async';

import 'package:flutter/material.dart';

/// Placeholder for a figure the source has not reported. A dash says "unknown";
/// a zero would say "nothing happened", which is a different claim.
const String kUsageUnknownFigure = '—';

/// What the Current model card says once the user has turned the model name
/// off (V2.3 §2.4, "toggle for model-name visibility").
///
/// This is deliberately not [kUsageUnknownFigure]. A dash means the source never
/// named a model; reusing it here would turn a user's display choice into a
/// claim about the data, which is the one substitution this file exists to avoid.
const String kUsageHiddenFigure = 'Hidden';

/// What a usage source actually reported.
///
/// Every field is optional on purpose: a partial snapshot is normal, and the
/// screen must be able to say which figures it knows and which it does not.
@immutable
class UsageSnapshot {
  const UsageSnapshot({
    this.tokensUsed,
    this.costUsd,
    this.activeModel,
    this.requestsUsed,
    this.requestsLimit,
    this.capturedAt,
  });

  /// Nothing has been reported at all — the empty state, not a zeroed one.
  static const UsageSnapshot none = UsageSnapshot();

  final int? tokensUsed;
  final double? costUsd;

  /// The model the router actually selected, as the source named it.
  final String? activeModel;
  final int? requestsUsed;
  final int? requestsLimit;

  /// When the source took the reading. Null means the source did not say.
  final DateTime? capturedAt;

  /// True when not a single figure is present.
  bool get isEmpty =>
      tokensUsed == null &&
      costUsd == null &&
      activeModel == null &&
      requestsUsed == null &&
      requestsLimit == null;
}

/// The three states a usage source can be in, plus "no source at all" which the
/// screen represents by holding no state at all.
sealed class UsageState {
  const UsageState();
}

/// A read is in flight and nothing may be claimed yet.
final class UsageLoading extends UsageState {
  const UsageLoading();
}

/// The source failed. [message] is the reason it gave, never a guess.
final class UsageFailed extends UsageState {
  const UsageFailed(this.message);

  final String message;
}

/// A real snapshot arrived.
final class UsageAvailable extends UsageState {
  const UsageAvailable(this.snapshot);

  final UsageSnapshot snapshot;
}

class UsageDashboardScreen extends StatefulWidget {
  const UsageDashboardScreen({super.key, this.source, this.onRetry});

  /// The real usage source. Null means nothing is wired, and the screen reports
  /// that instead of inventing a dashboard.
  final Stream<UsageState>? source;

  /// Handler for the failure state's retry control. Null renders no control,
  /// because a button that cannot do anything is a lie.
  final VoidCallback? onRetry;

  @override
  State<UsageDashboardScreen> createState() => _UsageDashboardScreenState();
}

class _UsageDashboardScreenState extends State<UsageDashboardScreen> {
  StreamSubscription<UsageState>? _subscription;
  UsageState? _state;

  /// Whether the Current model card may name the model (V2.3 §2.4).
  ///
  /// This is view state, held here for the lifetime of this screen instance for
  /// the same reason `_state` is: it is what this screen is displaying, not what
  /// the source reported. [UsageSnapshot] keeps whatever the source said — the
  /// toggle never rewrites `activeModel`, so hiding the name cannot turn a
  /// reported model into an unreported one for anything that reads the snapshot.
  ///
  /// Defaults to visible: the card has always shown the name, and a spec that
  /// asks for a toggle does not ask for a changed default.
  bool _showModelName = true;

  @override
  void initState() {
    super.initState();
    _bind(widget.source);
  }

  @override
  void didUpdateWidget(UsageDashboardScreen oldWidget) {
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

  void _bind(Stream<UsageState>? source) {
    if (source == null) {
      return;
    }
    // Until the source says something, the honest answer is "still reading".
    _state = const UsageLoading();
    _subscription = source.listen(
      (UsageState state) {
        if (mounted) setState(() => _state = state);
      },
      onError: (Object error) {
        if (mounted) setState(() => _state = UsageFailed('$error'));
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with NOIr branding
              Row(
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
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'STATS',
                      style: TextStyle(
                        color: Color(0xFF888888),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(color: Color(0xFF1A1A1A), thickness: 1, height: 1),
              const SizedBox(height: 24),
              const Text(
                'Usage Dashboard',
                style: TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 24,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  /// Exactly one honest state: still reading, no source, failed, empty, or the
  /// figures a real snapshot reported.
  Widget _buildBody() {
    final state = _state;
    if (state == null) {
      return const _UsageNotice(
        title: 'No usage source is connected.',
        detail:
            'Nothing is shown because no usage source is wired to this '
            'screen.',
      );
    }
    if (state is UsageLoading) {
      return const _UsageNotice(
        title: 'Reading usage…',
        detail: 'Waiting for the usage source to report.',
        busy: true,
      );
    }
    if (state is UsageFailed) {
      return _UsageNotice(
        title: state.message,
        detail: 'Usage could not be read, so no figure is shown.',
        retry: widget.onRetry,
      );
    }
    final snapshot = (state as UsageAvailable).snapshot;
    if (snapshot.isEmpty) {
      return const _UsageNotice(
        title: 'No usage has been recorded yet.',
        detail: 'A snapshot arrived without a single reported figure.',
      );
    }
    return _SnapshotBody(
      snapshot: snapshot,
      showModelName: _showModelName,
      onModelNameVisibilityChanged: _setModelNameVisible,
    );
  }

  /// The toggle is the only writer of `_showModelName`, and it lives here with
  /// `_state` so the preference cannot outlive the screen that was showing it.
  void _setModelNameVisible(bool visible) {
    if (!mounted || visible == _showModelName) {
      return;
    }
    setState(() => _showModelName = visible);
  }
}

class _SnapshotBody extends StatelessWidget {
  const _SnapshotBody({
    required this.snapshot,
    required this.showModelName,
    required this.onModelNameVisibilityChanged,
  });

  final UsageSnapshot snapshot;

  /// Whether the model identifier may be printed. See `_showModelName` on the
  /// screen's state.
  final bool showModelName;

  /// Handed straight to the toggle; the body itself holds no preference.
  final ValueChanged<bool> onModelNameVisibilityChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = snapshot.tokensUsed;
    final cost = snapshot.costUsd;
    final used = snapshot.requestsUsed;
    final limit = snapshot.requestsLimit;
    final rpm = used == null
        ? kUsageUnknownFigure
        : limit == null
        ? '$used req/min'
        : '$used / $limit req/min';
    final capturedAt = snapshot.capturedAt;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _MetricCard(
          label: 'Tokens used today',
          value: tokens?.toString() ?? kUsageUnknownFigure,
        ),
        const SizedBox(height: 10),
        _MetricCard(
          label: 'Cost today',
          value: cost == null
              ? kUsageUnknownFigure
              : '\$${cost.toStringAsFixed(2)}',
        ),
        const SizedBox(height: 10),
        _MetricCard(
          label: 'Current model',
          // Hidden is a state the user chose, so it is named rather than
          // blanked, and it is muted so it cannot be mistaken for a reading.
          value: showModelName
              ? snapshot.activeModel ?? kUsageUnknownFigure
              : kUsageHiddenFigure,
          valueMuted: !showModelName,
        ),
        const SizedBox(height: 10),
        // Only offered when there is a name to hide. A switch over a figure the
        // source never reported would be a control that does nothing.
        if (snapshot.activeModel != null) ...[
          _ModelVisibilityRow(
            visible: showModelName,
            onChanged: onModelNameVisibilityChanged,
          ),
          const SizedBox(height: 10),
        ],
        _MetricCard(label: 'RPM headroom', value: rpm),
        const SizedBox(height: 16),
        Text(
          capturedAt == null
              ? 'Not yet reported by a tracker.'
              : 'Reported at ${_stamp(capturedAt)}',
          style: const TextStyle(
            color: Color(0xFF5A5A5A),
            fontSize: 11,
            fontWeight: FontWeight.w300,
          ),
        ),
      ],
    );
  }
}

/// Loading, unavailable, empty and failure all read the same way: one line of
/// what is true, one line of why, and a retry only when one can do something.
class _UsageNotice extends StatelessWidget {
  const _UsageNotice({
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

/// Shared by every screen in this directory: a control that is only drawn when
/// it has a real handler behind it.
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

/// V2.3 §2.4's "toggle for model-name visibility", drawn the way §2.5 draws the
/// policy toggles: a Switch row in a bordered monochrome container.
///
/// The switch is themed entirely in V2.3 tokens rather than inheriting the
/// framework's, because the framework default is an accent colour and this
/// screen is "zero accent colours". Both states are greyscale, so the switch
/// reads as on/off by position and value, not by hue.
class _ModelVisibilityRow extends StatelessWidget {
  const _ModelVisibilityRow({required this.visible, required this.onChanged});

  final bool visible;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
      ),
      // The tile's own Material has to sit inside the decorated container,
      // otherwise the framework rejects the tile as having invisible ink.
      child: Material(
        color: Colors.transparent,
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Show model name',
            style: TextStyle(
              color: Color(0xFFE5E5E5),
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
          ),
          // Says which of the two states the screen is in, so "hidden" is a
          // choice the user can see they made rather than a card that went quiet.
          subtitle: Text(
            visible
                ? 'The Current model card names the model.'
                : 'The Current model card reads "$kUsageHiddenFigure".',
            style: const TextStyle(
              color: Color(0xFFB0B0B0),
              fontSize: 11,
              height: 1.3,
            ),
          ),
          value: visible,
          onChanged: onChanged,
          activeThumbColor: const Color(0xFFFFFFFF),
          activeTrackColor: const Color(0xFF2A2A2A),
          inactiveThumbColor: const Color(0xFF2A2A2A),
          inactiveTrackColor: const Color(0xFF1E1E1E),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    this.valueMuted = false,
  });

  final String label;
  final String value;

  /// Draws the value in muted grey even though it is not the unknown dash —
  /// used for the "Hidden" state, which is a deliberate state and not a
  /// reading, and must not look like one.
  final bool valueMuted;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A1A1A), width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFFB0B0B0),
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // A long model identifier has to ellipsize rather than overflow.
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: value == kUsageUnknownFigure || valueMuted
                    ? const Color(0xFF5A5A5A)
                    : const Color(0xFFFFFFFF),
                fontSize: 15,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Local, timezone-independent stamp so a reading reads the same everywhere.
String _stamp(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
