import 'package:flutter/material.dart';
import 'package:noir_android_app/core/constants.dart';

final ThemeData noirTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: NoirColors.black,
  colorScheme: const ColorScheme.dark(
    background: NoirColors.black,
    surface: NoirColors.gray900,
    onBackground: NoirColors.white,
    onSurface: NoirColors.white,
    primary: NoirColors.white,
    secondary: NoirColors.gray200,
  ),
  textTheme: const TextTheme(
    displayLarge: TextStyle(color: NoirColors.white, fontSize: 32),
    displayMedium: TextStyle(color: NoirColors.white, fontSize: 24),
    displaySmall: TextStyle(color: NoirColors.white, fontSize: 20),
    bodyLarge: TextStyle(color: NoirColors.white, fontSize: 16),
    bodyMedium: TextStyle(color: NoirColors.white, fontSize: 14),
    bodySmall: TextStyle(color: NoirColors.white, fontSize: 12),
    labelLarge: TextStyle(color: NoirColors.white, fontSize: 14),
    labelMedium: TextStyle(color: NoirColors.white, fontSize: 12),
    labelSmall: TextStyle(color: NoirColors.white, fontSize: 10),
  ),
  iconTheme: const IconThemeData(color: NoirColors.white),
  dividerColor: NoirColors.gray700,
);