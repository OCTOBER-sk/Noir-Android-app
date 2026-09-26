// lib/ui/accessibility_status_view.dart — the one place "is the service
// actually connected?" is drawn.
//
// Both the Command Centre header and the Safety Center render through these
// widgets so there is a single definition of the fail-closed state: a service
// that is unreachable, disconnected, or gesture-less is never drawn as ready,
// and the remedy is always spelled out instead of leaving a blank pill.
import 'package:flutter/material.dart';

import '../core/theme/noir_theme.dart';
import '../platform/accessibility_status.dart';

/// Compact header pill. One line, never wider than the space it is given.
class AccessibilityStatusPill extends StatelessWidget {
  const AccessibilityStatusPill({
    super.key,
    required this.status,
    required this.onTap,
  });

  final AccessibilityStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ready = status.isReady;
    return Semantics(
      button: true,
      enabled: true,
      label: '${status.headline}. Tap to open the Safety Center.',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: ready
                    ? const Color(0xFF2A2A2A)
                    : const Color(0xFF3A2A2A),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  ready ? Icons.accessibility_new_rounded : Icons.link_off,
                  size: 14,
                  color: ready ? const Color(0xFF888888) : const Color(0xFFB0B0B0),
                ),
                const SizedBox(width: 6),
                Text(
                  ready ? 'Service on' : 'Service off',
                  style: const TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full status panel for the Safety Center: headline, the real capability
/// flags, and what the user has to do about it.
class AccessibilityStatusPanel extends StatelessWidget {
  const AccessibilityStatusPanel({
    super.key,
    required this.status,
    required this.isLoading,
    required this.onRefresh,
  });

  final AccessibilityStatus status;
  final bool isLoading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final remedy = status.remedy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                status.headline,
                style: const TextStyle(
                  color: Color(0xFFE5E5E5),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (isLoading)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFF5A5A5A),
                  ),
                ),
              ),
            _RefreshButton(onPressed: onRefresh, busy: isLoading),
          ],
        ),
        const SizedBox(height: 10),
        _CapabilityRow(
          label: 'Service connected',
          value: status.connected,
        ),
        _CapabilityRow(
          label: 'May dispatch gestures',
          value: status.canDispatchGesture,
        ),
        _CapabilityRow(
          label: 'May read screen content',
          value: status.canReadScreen,
        ),
        _CapabilityRow(
          label: 'Holds a node dump',
          value: status.hasNodeDump,
        ),
        if (status.platformReachable) ...[
          const SizedBox(height: 6),
          Text(
            'Last dump: ${status.lastNodeCount} node(s) · '
            'stream sink ${status.runtimeSinkInstalled ? 'installed' : 'missing'}',
            style: const TextStyle(
              color: Color(0xFF888888),
              fontSize: 11,
            ),
          ),
          if (status.gateSource != null)
            Text(
              'Gate authority: ${status.gateSource}',
              style: const TextStyle(
                color: Color(0xFF5A5A5A),
                fontSize: 10,
              ),
            ),
        ],
        if (remedy != null) ...[
          const SizedBox(height: 8),
          Text(
            remedy,
            style: const TextStyle(
              color: Color(0xFFB0B0B0),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({required this.label, required this.value});

  final String label;
  final bool value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            value ? Icons.check_circle_outline : Icons.cancel_outlined,
            size: 14,
            color: value ? const Color(0xFFB0B0B0) : const Color(0xFF5A5A5A),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: value ? NoirColors.textSecondary : const Color(0xFF888888),
                fontSize: 13,
              ),
            ),
          ),
          Text(
            value ? 'yes' : 'no',
            style: TextStyle(
              color: value ? NoirColors.textMuted : const Color(0xFF5A5A5A),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.onPressed, required this.busy});

  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: !busy,
      label: 'Refresh accessibility status',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onPressed,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: Text(
              'Refresh',
              style: TextStyle(
                color: busy ? const Color(0xFF4A4A4A) : const Color(0xFFB0B0B0),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
