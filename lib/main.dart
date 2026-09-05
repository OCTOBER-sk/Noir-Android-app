import 'package:flutter/material.dart';
import 'core/theme/noir_theme.dart';
import 'core/constants.dart';

void main() => runApp(const NoirApp());

class NoirApp extends StatelessWidget {
  const NoirApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Noir',
      theme: noirTheme,
      darkTheme: noirTheme,
      themeMode: ThemeMode.dark,
      home: const Scaffold(
        backgroundColor: NoirColors.black,
        appBar: null,
        body: Center(
          child: Text('Noir', style: TextStyle(color: NoirColors.white, fontSize: 32)),
        ),
      ),
    );
  }
}