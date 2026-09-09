// lib/ui/safety_center_screen.dart — V2.3 §2.5 (D9 — Safety Center)
// Flat list: timestamp, stripped reason code (not raw payload by default — expand for details),
// Policy toggles (blacklist entries, confirmation thresholds) as Switch rows.
class SafetyCenterScreen extends StatelessWidget {
  const SafetyCenterScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF161412),
      appBar: AppBar(title: const Text('Safety Center', style: TextStyle(color: Color(0xFFF2EFE9)))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Injection attempts (A6a audit)', style: TextStyle(color: Color(0xFFF2EFE9), fontSize: 16, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          ListTile(title: Text('No attempts recorded yet', style: TextStyle(color: Color(0xFFB0B0B0))),
            subtitle: Text('Screen-Content Sanitizer active (REASON_ZERO_ALPHA, REASON_OFF_SCREEN, REASON_ZERO_WIDTH, REASON_BIDI_OVERRIDE)', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 10))),
          SizedBox(height: 16),
          Text('Policy toggles', style: TextStyle(color: Color(0xFFF2EFE9), fontWeight: FontWeight.bold)),
          SwitchListTile(title: Text('Enable Screen Content Sanitizer', style: TextStyle(color: Color(0xFFF2EFE9))), value: true, onChanged: (v){}),
        ],
      ),
    );
  }
}
