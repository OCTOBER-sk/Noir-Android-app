// lib/ui/usage_dashboard_screen.dart — D6 (V2.3 §2.4) — polished smooth layout
import 'package:flutter/material.dart';
import '../core/theme/noir_theme.dart';

class UsageDashboardScreen extends StatelessWidget {
  const UsageDashboardScreen({super.key});

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
                  const Text('NOIr', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 5)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('STATS', style: TextStyle(color: Color(0xFF888888), fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: 1)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Divider(color: const Color(0xFF1A1A1A), thickness: 1, height: 1),
              const SizedBox(height: 24),
              Text('Usage Dashboard', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 24, fontWeight: FontWeight.w300, letterSpacing: -0.3)),
              const SizedBox(height: 28),
              _MetricCard(label: 'Tokens used today', value: '1,240'),
              const SizedBox(height: 10),
              _MetricCard(label: 'Cost today', value: '\$0.00'),
              const SizedBox(height: 10),
              _MetricCard(label: 'Current model', value: 'Noir Engine v2'),
              const SizedBox(height: 10),
              _MetricCard(label: 'RPM headroom', value: '12 / 20 req/min'),
              const SizedBox(height: 28),
              // Rainbow-shifting tiny indicator
              Container(
                height: 4,
                width: 60,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: NoirColors.rainbowAccent, begin: Alignment.centerLeft, end: Alignment.centerRight),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  const _MetricCard({required this.label, required this.value});

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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: const Color(0xFFB0B0B0), fontSize: 14, fontWeight: FontWeight.w400)),
          Text(value, style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: 15, fontWeight: FontWeight.w500, letterSpacing: 0.2)),
        ],
      ),
    );
  }
}
