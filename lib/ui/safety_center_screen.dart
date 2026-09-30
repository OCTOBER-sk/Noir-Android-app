// lib/ui/safety_center_screen.dart — D9 (V2.3 §2.5)
//
// The two live sections are real, not mock data:
//
//   * Accessibility service — read through NativeBridge.serviceStatus(), so an
//     unreachable platform renders as unavailable instead of as healthy.
//   * Screen audit (A6a) — the deterministic Sanitizer run over a dump that
//     actually came from the platform via NativeBridge.getSanitizedNodes() /
//     the screenNodeDumps push stream.
//
// A third section, the safety log, is fed by whatever the app injects: the
// screen renders the [SafetyEvent]s it is handed and admits when it has none.
// `main.dart` hands it the graph's own `NoirComposition.safetyEvents()`, so the
// rows are the decisions this process really made — a blocked gesture, a
// sanitized dump, a confirmation that timed out, a low-confidence reflection
// routed into A4 recovery. The policy toggle is drawn inert on purpose — a
// switch that reads "on" while no policy gate is bound to it would be the most
// expensive lie in this file.
//
// Nothing here calls a MethodChannel and nothing here dispatches a gesture:
// the audit is a read-only consequence of the platform dump.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/mcp_composition.dart';
import '../data/mcp_server_settings.dart' show McpServerSettings;
import '../platform/accessibility_status.dart';
import '../platform/native_bridge.dart';
import '../safety/screen_content_sanitizer.dart' show SanitizedItem;
import 'accessibility_status_view.dart';

/// What a safety log entry is about.
///
/// [recovery] is the A4 path: a reflection the critic scored too low to act on.
/// It is its own kind rather than a `policy` entry because the thing a user needs
/// to know about it is not that a rule said no — it is which run degraded, how
/// low its confidence was and which recovery path was chosen.
enum SafetyEventKind { policy, sanitization, confirmation, dispatch, recovery }

/// What the policy engine decided about it.
enum SafetyEventOutcome { allowed, blocked, awaitingConfirmation, unknown }

/// One real decision the safety pipeline made.
@immutable
class SafetyEvent {
  const SafetyEvent({
    required this.id,
    required this.summary,
    this.kind = SafetyEventKind.policy,
    this.outcome = SafetyEventOutcome.unknown,
    this.detail,
    this.occurredAt,
  });

  final String id;
  final String summary;
  final SafetyEventKind kind;
  final SafetyEventOutcome outcome;

  /// Whatever else the log had to say about this decision.
  final String? detail;

  /// When the decision was made. Null means the log did not say.
  final DateTime? occurredAt;

  /// Wire-stable tag, e.g. `POLICY_BLOCKED`.
  String get badge =>
      '${kind.name.toUpperCase()}_${outcome.name.toUpperCase()}';
}

sealed class SafetyEventState {
  const SafetyEventState();
}

final class SafetyEventLoading extends SafetyEventState {
  const SafetyEventLoading();
}

final class SafetyEventFailed extends SafetyEventState {
  const SafetyEventFailed(this.message);

  final String message;
}

final class SafetyEventAvailable extends SafetyEventState {
  const SafetyEventAvailable(this.events);

  final List<SafetyEvent> events;
}

class SafetyCenterScreen extends StatefulWidget {
  const SafetyCenterScreen({
    super.key,
    this.bridge,
    this.log,
    this.onRetryLog,
    this.mcp,
  });

  /// The accessibility bridge. Null uses [NativeBridge.instance]; tests inject
  /// their own so the channel can be mocked.
  final NativeBridge? bridge;

  /// The real safety log. Null means nothing is wired, and the section says so
  /// instead of listing decisions that were never made.
  final Stream<SafetyEventState>? log;

  /// Handler for the log's retry control, or null for no control.
  final VoidCallback? onRetryLog;

  /// What the composition root built for MCP. Null means this screen has not
  /// been told, and says so; it does not assume "no servers configured", which
  /// is a different and much stronger claim.
  final McpWiring? mcp;

  @override
  State<SafetyCenterScreen> createState() => _SafetyCenterScreenState();
}

class _SafetyCenterScreenState extends State<SafetyCenterScreen> {
  late final AccessibilityStatusController _status;
  late final ScreenAuditController _audit;

  StreamSubscription<SafetyEventState>? _logSubscription;
  SafetyEventState? _logState;

  @override
  void initState() {
    super.initState();
    final bridge = widget.bridge;
    _status = AccessibilityStatusController(bridge: bridge)
      ..addListener(_onChanged);
    _audit = ScreenAuditController(bridge: bridge)..addListener(_onChanged);
    _bindLog(widget.log);
    // Both loads resolve to their fail-closed state on error, so neither can
    // throw out of initState and leave a blank screen behind.
    _status.refresh();
    _audit.refresh();
  }

  @override
  void didUpdateWidget(SafetyCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.log, widget.log)) {
      return;
    }
    _bindLog(widget.log);
  }

  @override
  void dispose() {
    _unbindLog();
    _status
      ..removeListener(_onChanged)
      ..dispose();
    _audit
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _bindLog(Stream<SafetyEventState>? log) {
    _unbindLog();
    if (log == null) {
      return;
    }
    _logState = const SafetyEventLoading();
    _logSubscription = log.listen(
      (SafetyEventState state) {
        if (mounted) setState(() => _logState = state);
      },
      onError: (Object error) {
        if (mounted) setState(() => _logState = SafetyEventFailed('$error'));
      },
    );
  }

  void _unbindLog() {
    final subscription = _logSubscription;
    _logSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    _logState = null;
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _refreshAll() {
    _status.refresh();
    _audit.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _BackButton(),
                  const SizedBox(width: 12),
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
                      'SAFETY',
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
              const SizedBox(height: 20),
              const Text(
                'Safety Center',
                style: TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 24,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Live service status, screen audit & policy log',
                style: TextStyle(
                  color: Color(0xFF888888),
                  fontSize: 13,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Accessibility service',
                style: TextStyle(
                  color: Color(0xFFE5E5E5),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 12),
              AccessibilityStatusPanel(
                status: _status.status,
                isLoading: _status.isLoading,
                onRefresh: _refreshAll,
              ),
              const SizedBox(height: 28),
              const Text(
                'Screen audit',
                style: TextStyle(
                  color: Color(0xFFE5E5E5),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'A6a sanitizer output for the last real dump',
                style: TextStyle(
                  color: Color(0xFF888888),
                  fontSize: 12,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 12),
              _buildAudit(),
              const SizedBox(height: 28),
              const Text(
                'Recent safety events',
                style: TextStyle(
                  color: Color(0xFFE5E5E5),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Decisions the safety pipeline reported',
                style: TextStyle(
                  color: Color(0xFF888888),
                  fontSize: 12,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 12),
              _buildLog(),
              const SizedBox(height: 28),
              const Text(
                'MCP servers',
                style: TextStyle(
                  color: Color(0xFFE5E5E5),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Read from your own configuration, never from a default server',
                style: TextStyle(
                  color: Color(0xFF888888),
                  fontSize: 12,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 12),
              _McpPanel(wiring: widget.mcp),
              const SizedBox(height: 28),
              const Text(
                'Policy toggles',
                style: TextStyle(
                  color: Color(0xFFE5E5E5),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 12),
              const _SwitchRow(label: 'Require biometric (risk >= 2)'),
            ],
          ),
        ),
      ),
    );
  }

  /// The audit is only ever one of three honest states: still reading, no
  /// screen data at all, or a real dump with real findings.
  Widget _buildAudit() {
    if (_audit.isLoading) {
      return const _AuditNotice(
        text: 'Reading the screen through the accessibility service…',
      );
    }
    final audit = _audit.audit;
    if (!audit.available) {
      return _AuditNotice(
        text:
            'No screen data: the accessibility service is not connected '
            '(${audit.code ?? 'UNKNOWN'}).',
      );
    }
    if (audit.stripped.isEmpty) {
      return _AuditNotice(
        text:
            'Last dump read cleanly: ${audit.nodeCount} node(s), '
            '${audit.cleanTextNodes.length} text node(s), nothing stripped.',
      );
    }
    return Column(
      children: [
        _AuditNotice(
          text:
              'Last dump: ${audit.nodeCount} node(s) read, '
              '${audit.blockedCount} stripped by the A6a sanitizer.',
        ),
        const SizedBox(height: 10),
        for (final item in audit.stripped) ...[
          _AuditRow(item: item),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// The log is only ever one of four honest states: still reading, no log
  /// connected, a real failure, or the decisions that were actually reported.
  Widget _buildLog() {
    final state = _logState;
    if (state == null) {
      return const _AuditNotice(text: 'No safety log is connected.');
    }
    if (state is SafetyEventLoading) {
      return const _AuditNotice(text: 'Reading the safety log…');
    }
    if (state is SafetyEventFailed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AuditNotice(text: state.message),
          const SizedBox(height: 10),
          if (widget.onRetryLog != null)
            _RetryLogButton(onPressed: widget.onRetryLog!),
        ],
      );
    }
    final events = (state as SafetyEventAvailable).events;
    if (events.isEmpty) {
      return const _AuditNotice(text: 'No safety events have been recorded.');
    }
    return Column(
      children: [
        for (final event in events) ...[
          _SafetyEventRow(event: event),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// One real decision, drawn from the log entry and nothing else.
class _SafetyEventRow extends StatelessWidget {
  const _SafetyEventRow({required this.event});

  final SafetyEvent event;

  @override
  Widget build(BuildContext context) {
    final detail = event.detail;
    final occurredAt = event.occurredAt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1A1A1A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  event.badge,
                  style: const TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                occurredAt == null ? 'time unknown' : _clockOf(occurredAt),
                style: const TextStyle(
                  color: Color(0xFF5A5A5A),
                  fontSize: 10,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            event.summary,
            style: const TextStyle(
              color: Color(0xFFE5E5E5),
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(
              detail,
              style: const TextStyle(
                color: Color(0xFF888888),
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Pops when there is somewhere to go back to; inert on a root route.
class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: Navigator.of(context).canPop(),
      label: 'Back',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.of(context).maybePop(),
          borderRadius: BorderRadius.circular(20),
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(
              Icons.arrow_back_rounded,
              size: 18,
              color: Color(0xFF888888),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuditNotice extends StatelessWidget {
  const _AuditNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1A1A1A), width: 1),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFB0B0B0),
          fontSize: 12,
          height: 1.4,
        ),
      ),
    );
  }
}

/// Log retry, drawn only when a handler is actually wired to it.
class _RetryLogButton extends StatelessWidget {
  const _RetryLogButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: 'Retry log',
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
            child: const Text(
              'Retry log',
              style: TextStyle(
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

/// One real A6a finding, rendered from the sanitizer's own output.
class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.item});

  final SanitizedItem item;

  static const int _maxTextChars = 72;

  @override
  Widget build(BuildContext context) {
    final raw = item.text;
    final clipped = raw.length > _maxTextChars
        ? '${raw.substring(0, _maxTextChars)}…'
        : raw;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1A1A1A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  item.reason.name,
                  style: const TextStyle(
                    color: Color(0xFFE5E5E5),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'node #${item.nodeIndex}',
                  style: const TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Stripped by the A6a sanitizer — not sent to any model.',
            style: const TextStyle(
              color: Color(0xFF888888),
              fontSize: 11,
              fontWeight: FontWeight.w400,
            ),
          ),
          if (clipped.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '“$clipped”',
              style: const TextStyle(
                color: Color(0xFF5A5A5A),
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A setting this screen cannot enforce. It is drawn off and inert, with the
/// reason on screen, rather than switched on and pretending to be in control of
/// a policy gate nothing is wired to.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1A1A1A), width: 1),
      ),
      // The tile's own Material has to sit inside the decorated container,
      // otherwise the framework rejects the tile as having invisible ink.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFE5E5E5),
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                ),
              ),
              value: false,
              onChanged: null,
              activeThumbColor: Color(0xFFFFFFFF),
              inactiveThumbColor: Color(0xFF2A2A2A),
              inactiveTrackColor: Color(0xFF1E1E1E),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Not wired to a policy gate yet — this screen cannot enforce it.',
            style: TextStyle(
              color: Color(0xFF5A5A5A),
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Local clock reading of a reported moment, to the second.
String _clockOf(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

/// The MCP capability this build actually has.
///
/// Three states, and the difference between them is the whole point: a build
/// that could not open its configuration store is NOT the same as a build with
/// no servers configured, and neither is the same as a list of servers the user
/// really entered. Collapsing any of them into "MCP: none" would tell the user
/// their configuration was empty when in fact the app could not read it.
class _McpPanel extends StatelessWidget {
  const _McpPanel({required this.wiring});

  final McpWiring? wiring;

  @override
  Widget build(BuildContext context) {
    final McpWiring? wiring = this.wiring;
    if (wiring == null) {
      return const _McpNotice(
        'MCP status is unknown: nothing wired this screen to the app\'s '
        'configuration.',
      );
    }
    if (wiring case final McpWiringFailed failure) {
      return _McpNotice('MCP is unavailable. ${failure.reason}');
    }
    final McpComposition composition = (wiring as McpWired).composition;
    return FutureBuilder<List<McpServerSettings>>(
      future: composition.configuredServers(),
      builder: (BuildContext context, AsyncSnapshot<List<McpServerSettings>> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _McpNotice('Reading your MCP server configuration…');
        }
        if (snapshot.hasError) {
          return _McpNotice(
            'The MCP server configuration could not be read: '
            '${snapshot.error}',
          );
        }
        final List<McpServerSettings> servers =
            snapshot.data ?? const <McpServerSettings>[];
        if (servers.isEmpty) {
          return const _McpNotice(
            'No MCP server is configured. Noir does not ship a default one, so '
            'it has no MCP capability until you add one.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final McpServerSettings server in servers)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${server.displayName} — ${server.transportKind}, '
                  '${server.allowedTools.length} allowed tool(s)',
                  style: const TextStyle(
                    color: Color(0xFFB0B0B0),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            const Text(
              'A tool call is refused unless the tool is on the allowlist and '
              'the PolicyEngine allows it. High-risk tools also need a '
              'confirmation this build can collect but a biometric it cannot.',
              style: TextStyle(
                color: Color(0xFF5A5A5A),
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _McpNotice extends StatelessWidget {
  const _McpNotice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1A1A1A)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF888888),
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}
