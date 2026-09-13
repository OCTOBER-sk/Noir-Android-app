// lib/ui/safety_center_screen.dart — D9 (V2.3 §2.5) — polished smooth layout
import 'package:flutter/material.dart';
import '../core/theme/noir_theme.dart';

class SafetyCenterScreen extends StatelessWidget {
  const SafetyCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('NOIr', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 5)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('SAFETY', style: TextStyle(color: Color(0xFF888888), fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: 1)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Divider(color: const Color(0xFF1A1A1A), thickness: 1, height: 1),
              const SizedBox(height: 20),
              Text('Safety Center', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 24, fontWeight: FontWeight.w300, letterSpacing: -0.3)),
              const SizedBox(height: 4),
              Text('Audit log & policy controls', style: TextStyle(color: Color(0xFF888888), fontSize: 13, letterSpacing: 0.3)),
              const SizedBox(height: 24),
              _LogRow(time: '14:03', reason: 'REASON_ZERO_ALPHA', sanitized: true),
              const SizedBox(height: 10),
              _LogRow(time: '14:07', reason: 'REASON_OFF_SCREEN', sanitized: false),
              const SizedBox(height: 28),
              Text('Policy toggles', style: TextStyle(color: Color(0xFFE5E5E5), fontSize: 16, fontWeight: FontWeight.w500, letterSpacing: -0.2)),
              const SizedBox(height: 12),
              _SwitchRow(label: 'Require biometric (risk >= 2)'),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final String time;
  final String reason;
  final bool sanitized;
  const _LogRow({required this.time, required this.reason, required this.sanitized});

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(time, style: TextStyle(color: Color(0xFF888888), fontSize: 12, fontWeight: FontWeight.w500)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: sanitized ? const Color(0xFF1E1E1E) : const Color(0xFF151515),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(sanitized ? 'BLOCKED' : 'FLAGGED', style: TextStyle(color: sanitized ? Color(0xFF888888) : Color(0xFFE5E5E5), fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(reason, style: TextStyle(color: Color(0xFFE5E5E5), fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(sanitized ? 'Sanitized & blocked' : 'Flagged — not blocked',
              style: TextStyle(color: Color(0xFF888888), fontSize: 11, fontWeight: FontWeight.w400)),
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
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 15, fontWeight: FontWeight.w400)),
        value: true,
        onChanged: (v) {},
        activeColor: Color(0xFFFFFFFF),
        inactiveThumbColor: Color(0xFF2A2A2A),
        inactiveTrackColor: Color(0xFF1E1E1E),
      ),
    );
  }
}
