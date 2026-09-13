// lib/ui/skill_manager_screen.dart — D7 (V2.3 §2.3) — polished smooth layout
import 'package:flutter/material.dart';
import '../core/theme/noir_theme.dart';

class SkillManagerScreen extends StatelessWidget {
  final List<Map<String, String>> skills = const [
    {'name': 'Message Triage', 'state': 'active'},
    {'name': 'Form Fill', 'state': 'validated'},
    {'name': 'Photo Note', 'state': 'needs_review'},
  ];
  const SkillManagerScreen({super.key});

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
                    child: const Text('SKILLS', style: TextStyle(color: Color(0xFF888888), fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: 1)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Divider(color: const Color(0xFF1A1A1A), thickness: 1, height: 1),
              const SizedBox(height: 20),
              Text('Skill Manager', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 24, fontWeight: FontWeight.w300, letterSpacing: -0.3)),
              const SizedBox(height: 4),
              Text('Manage automation skills', style: TextStyle(color: Color(0xFF888888), fontSize: 13, letterSpacing: 0.3)),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: skills.length,
                  itemBuilder: (context, index) {
                    final s = skills[index];
                    final needsReview = s['state'] == 'needs_review';
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F0F0F),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: needsReview ? const Color(0xFF2A2A2A) : const Color(0xFF151515),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          if (needsReview)
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(colors: NoirColors.rainbowAccent, begin: Alignment.topLeft, end: Alignment.bottomRight),
                              ),
                            )
                          else
                            const SizedBox(width: 8),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s['name']!, style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 16, fontWeight: FontWeight.w500, letterSpacing: -0.2)),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Text(s['state']!.replaceAll('_', ' '), style: TextStyle(color: needsReview ? Color(0xFFE5E5E5) : Color(0xFF888888), fontSize: 12, fontWeight: FontWeight.w400)),
                                    const SizedBox(width: 8),
                                    Text('last used 2h ago', style: TextStyle(color: Color(0xFF666666), fontSize: 11, fontWeight: FontWeight.w300)),
                                  ],
                                ),
                              ],
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
      ),
    );
  }
}
