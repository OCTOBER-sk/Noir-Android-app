import 'package:flutter/material.dart';
import 'package:noir_android_app/core/constants.dart';
import 'package:noir_android_app/core/theme/noir_theme.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';

void main() => runApp(const NoirApp());

/// Root widget for the Noir Android app.
class NoirApp extends StatelessWidget {
  const NoirApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Noir',
      theme: noirTheme,
      darkTheme: noirTheme,
      themeMode: ThemeMode.dark,
      home: const CommandCentreScreen(),
    );
  }
}
