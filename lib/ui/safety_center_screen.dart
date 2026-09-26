// lib/ui/safety_center_screen.dart — D9 (V2.3 §2.5) — polished smooth layout
//
// The two live sections are real, not mock data:
//
//   * Accessibility service — read through NativeBridge.serviceStatus(), so an
//     unreachable platform renders as unavailable instead of as healthy.
//   * Screen audit (A6a) — the deterministic Sanitizer run over a dump that
//     actually came from the platform via NativeBridge.getSanitizedNodes() /
//     the screenNodeDumps push stream.
//
// Nothing here calls a MethodChannel and nothing here dispatches a gesture:
// the audit is a read-only consequence of the platform dump.
import 'package:flutter/material.dart';

import '../platform/accessibility_status.dart';
import '../platform/native_bridge.dart';
import '../safety/screen_content_sanitizer.dart' show SanitizedItem;
import 'accessibility_status_view.dart';

class SafetyCenterScreen extends StatefulWidget {
  const SafetyCenterScreen({super.key, this.bridge});

  /// The accessibility bridge. Null uses [NativeBridge.instance]; tests inject
  /// their own so the channel can be mocked.
  final NativeBridge? bridge;

  @override
  State<SafetyCenterScreen> createState() => _SafetyCenterScreenState();
}

class _SafetyCenterScreenState extends State<SafetyCenterScreen> {
  late final AccessibilityStatusController _status;
  late final ScreenAuditController _audit;

  @override
  void initState() {
    super.initState();
    final bridge = widget.bridge;
    _status = AccessibilityStatusController(bridge: bridge)
      ..addListener(_onChanged);
    _audit = ScreenAuditController(bridge: bridge)..addListener(_onChanged);
    // Both loads resolve to their fail-closed state on error, so neither can
    // throw out of initState and leave a blank screen behind.
    _status.refresh();
    _audit.refresh();
  }

  @override
  void dispose() {
    _status
      ..removeListener(_onChanged)
      ..dispose();
    _audit
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
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
                  _BackButton(),
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
                'Live service status & screen audit',
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
        text: 'No screen data: the accessibility service is not connected '
            '(${audit.code ?? 'UNKNOWN'}).',
      );
    }
    if (audit.stripped.isEmpty) {
      return _AuditNotice(
        text: 'Last dump read cleanly: ${audit.nodeCount} node(s), '
            '${audit.cleanTextNodes.length} text node(s), nothing stripped.',
      );
    }
    return Column(
      children: [
        _AuditNotice(
          text: 'Last dump: ${audit.nodeCount} node(s) read, '
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
}

/// Pops when there is somewhere to go back to; inert on a root route.
class _BackButton extends StatelessWidget {
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
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

class _SwitchRow extends StatelessWidget {
  final String label;
  const _SwitchRow({required this.label});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1A1A1A), width: 1),
      ),
      // The tile's own Material has to sit inside the decorated container,
      // otherwise the framework rejects the tile as having invisible ink.
      child: Material(
        color: Colors.transparent,
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 15, fontWeight: FontWeight.w400)),
          value: true,
          onChanged: (v) {},
          activeThumbColor: Color(0xFFFFFFFF),
          inactiveThumbColor: Color(0xFF2A2A2A),
          inactiveTrackColor: Color(0xFF1E1E1E),
        ),
      ),
    );
  }
}
