import 'package:flutter/material.dart';
import 'ui/command_centre_screen.dart';

void main() => runApp(const NoirApp());

class NoirApp extends StatelessWidget {
  const NoirApp({super.key});

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
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const CommandCentreScreen()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/noir_logo.png', width: 200, height: 200, filterQuality: FilterQuality.high),
            const SizedBox(height: 24),
            const Text('Noir', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 4)),
            const SizedBox(height: 8),
            const Text('On-device automation', style: TextStyle(color: Color(0xFF888888), fontSize: 13, letterSpacing: 1)),
          ],
        ),
      ),
    );
  }
}
