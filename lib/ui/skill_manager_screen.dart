// lib/ui/skill_manager_screen.dart — V2.3 §2.3 (D7 — Skill Manager)
// Full-width rows; lifecycle labels (candidate/validated/draft/active/disabled/degraded/needs_review);
// needs_review badge (text-only, no color); last-used timestamp in textMuted.
class SkillManagerScreen extends StatelessWidget {
  const SkillManagerScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF161412),
      appBar: AppBar(title: const Text('Skills', style: TextStyle(color: Color(0xFFF2EFE9)))),
      body: ListView(
        children: [
          ListTile(title: Text('Sample Skill (needs_review)', style: TextStyle(color: Color(0xFFF2EFE9))),
            subtitle: Text('validated — last used 2h ago', style: TextStyle(color: Color(0xFFB0B0B0))),
            trailing: Text('needs_review', style: TextStyle(color: Color(0xFFE5E5E5), fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }
}
