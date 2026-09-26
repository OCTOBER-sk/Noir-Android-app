// lib/main.dart — the composition root.
//
// Nothing here fabricates state. The app builds the real objects it has
// (a ConversationController, a UsageTracker) and injects them into the screen
// that renders them; every screen that has no real source wired to it says so on
// screen instead of showing a plausible-looking placeholder.
import 'dart:async';

import 'package:flutter/material.dart';

import 'core/conversation_controller.dart';
import 'providers/usage_tracker.dart';
import 'ui/command_centre_screen.dart';

void main() => runApp(
  NoirApp(controller: ConversationController(), usage: UsageTracker()),
);

class NoirApp extends StatelessWidget {
  const NoirApp({super.key, this.controller, this.usage});

  /// The conversation the Command Centre renders. The app owns its lifetime.
  final ConversationController? controller;

  /// The real usage counters shown in the Command Centre header. Null renders
  /// "Usage idle" rather than a fabricated figure.
  final UsageTracker? usage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Noir',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF121212),
        scaffoldBackgroundColor: const Color(0xFF000000),
        fontFamily: 'Roboto',
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Color(0xFFE5E5E5)),
          bodyMedium: TextStyle(color: Color(0xFFB0B0B0)),
        ),
      ),
      home: SplashScreen(controller: controller, usage: usage),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.controller, this.usage});

  final ConversationController? controller;
  final UsageTracker? usage;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 1600), () {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => CommandCentreScreen(
                controller: widget.controller,
                usage: widget.usage,
              ),
            ),
          );
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/noir_logo.png',
              width: 200,
              height: 200,
              filterQuality: FilterQuality.high,
            ),
            const SizedBox(height: 24),
            const Text(
              'Noir',
              style: TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'On-device automation',
              style: TextStyle(
                color: Color(0xFF888888),
                fontSize: 13,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
