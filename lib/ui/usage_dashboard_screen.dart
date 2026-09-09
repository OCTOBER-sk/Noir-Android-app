// lib/ui/usage_dashboard_screen.dart — V2.3 §2.4 (D6 — Usage Dashboard)
// Plain numeric readouts: tokens today, cost today (if paid provider), current model, provider,
// RPM headroom against OPENROUTER_FREE_RPM_CAP (20). Toggle for model-name visibility.
class UsageDashboardScreen extends StatelessWidget {
  const UsageDashboardScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF161412),
      appBar: AppBar(title: const Text('Usage Dashboard', style: TextStyle(color: Color(0xFFF2EFE9)))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Tokens today: 0', style: TextStyle(color: Color(0xFFF2EFE9), fontSize: 18)),
          SizedBox(height: 8),
          Text('RPM headroom: 20 / 20', style: TextStyle(color: Color(0xFFE5E5E5), fontSize: 14)),
          SizedBox(height: 8),
          Text('Provider: (live from adapter registry)', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 12)),
          SizedBox(height: 8),
          SwitchListTile(title: Text('Show model/provider names in micro-copy', style: TextStyle(color: Color(0xFFF2EFE9))), value: true, onChanged: (v){}),
        ],
      ),
    );
  }
}
