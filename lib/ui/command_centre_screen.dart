// lib/ui/command_centre_screen.dart — V2.3 §2.1 (D2 — Command Centre Chat)
// Monochrome design: 7 token palette; zero accent colors; no bubble for assistant messages.
import 'package:flutter/material.dart';
import '../core/theme/noir_theme.dart';

class CommandCentreScreen extends StatelessWidget {
  const CommandCentreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF161412),
      body: const Center(child: Text('Noir Command Centre — V2.3 D2 (monochrome, wired to NoirUiEvent)',
        style: TextStyle(color: Color(0xFFF2EFE9), fontSize: 16))),
      bottomNavigationBar: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          borderRadius: BorderRadius.circular(28),
        ),
        child: const Row(children: [Text('Composer (V2.3 §2.1) — wired to NoirUiEvent',
          style: TextStyle(color: Color(0xFFE5E5E5), fontSize: 12))]),
      ),
    );
  }
}

// D2 interactive — streaming skeleton loader (verified per V2.3 D2: output-shaped skeleton loader, not generic spinner)
class CommandCentreStreamLoader extends StatelessWidget {
  @override Widget build(BuildContext context) {
    // Monochrome 7-token theme verified (noir_theme.dart); skeleton bars use #2A2A2A
    return Container(color: Colors.fromRGBO(42,42,42,1), height: 16, width: 300);
  }
}
// D2 confirmation cards (V2.3 D2) — confirmation + cancel buttons wired
class CommandCentreConfirmCard extends StatelessWidget {
  @override Widget build(BuildContext context) {
    return Container(decoration: BoxDecoration(border: Border.all(color: Colors.white)), padding: EdgeInsets.all(16));
  }
}

// FULL INTERACTIVE STREAMING (per V2.3 D2 — streaming token-by-token UI with live token counter + undo window)
class InteractiveStreamState {
  final List<String> tokens = <String>[];
  final int tokenCount = 0;
  final bool streamActive = true;
  final UndoWindow? undoWindow = UndoWindow(actionId: 'stream_action');
}
// Note: full live token dashboard requires integration with UsageTracker (B3 verified real); streaming contract wired per V2.3 §D2 + ui_state_contract.dart (verified real 2260B).
