// lib/ui/live_task_view.dart — D3 (V2.3 §2.2) — polished smooth layout
import 'package:flutter/material.dart';
import '../core/theme/noir_theme.dart';

class LiveTaskView extends StatelessWidget {
  final List<String> events;
  const LiveTaskView({super.key, required this.events});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with NOIr branding
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Row(
                children: [
                  const Text('NOIr', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 5)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('LIVE', style: TextStyle(color: Color(0xFF888888), fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1)),
                  ),
                ],
              ),
            ),
            Divider(color: const Color(0xFF1A1A1A), thickness: 1, height: 1, indent: 20, endIndent: 20),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final evt = events[index];
                  final isRecovering = evt.contains('recovering');
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: isRecovering ? const Color(0xFF1A1A1A) : const Color(0xFF0F0F0F),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isRecovering ? const Color(0xFF2A2A2A) : const Color(0xFF151515),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF000000).withOpacity(0.4),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Text('12:${34 + index}', style: TextStyle(color: NoirColors.textMuted, fontSize: 11, fontWeight: FontWeight.w500)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            evt,
                            style: TextStyle(
                              color: isRecovering ? const Color(0xFFFFFFFF) : const Color(0xFFE5E5E5),
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
