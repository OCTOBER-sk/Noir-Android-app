Agent: zeus
Task: VS.1 — Monochrome theme, package rename com.noir.noir_android_app → com.noir.android, theme test (V2.1 §0.1, §2)

Flutter SDK: /home/santhosh/flutter/flutter/bin/flutter (already installed)
Project dir: /home/santhosh/projects/Noir-Android-app
Current state: `flutter create` already ran. MainActivity is at android/app/src/main/kotlin/com/noir/noir_android_app/MainActivity.kt. build.gradle uses namespace "com.noir.noir_android_app". lib/main.dart exists with default counter app.

STEP 1 — Rename package everywhere: com.noir.noir_android_app → com.noir.android
  - mv android/app/src/main/kotlin/com/noir/noir_android_app android/app/src/main/kotlin/com/noir/android
  - Edit android/app/src/main/kotlin/com/noir/android/MainActivity.kt: change `package com.noir.noir_android_app` to `package com.noir.android`
  - Edit android/app/build.gradle: change `namespace = "com.noir.noir_android_app"` to `namespace = "com.noir.android"` and `applicationId = "com.noir.noir_android_app"` to `applicationId = "com.noir.android"`
  - grep -r "com.noir.noir_android_app" --include="*.kt" --include="*.gradle" --include="*.xml" . — must return ZERO matches after edits

STEP 2 — Write these 3 NEW files in ONE batch (use Write tool):
  1. lib/core/constants.dart:
     import 'package:flutter/material.dart';
     class NoirColors {
       static const Color black = Color(0xFF000000);
       static const Color white = Color(0xFFFFFFFF);
       static const Color gray900 = Color(0xFF121212);
       static const Color gray800 = Color(0xFF1E1E1E);
       static const Color gray700 = Color(0xFF2A2A2A);
       static const Color gray200 = Color(0xFFE5E5E5);
       static const Color gray400 = Color(0xFFB0B0B0);
     }

  2. lib/core/theme/noir_theme.dart:
     import 'package:flutter/material.dart';
     import '../constants.dart';
     final ThemeData noirTheme = ThemeData(
       brightness: Brightness.dark,
       scaffoldBackgroundColor: NoirColors.black,
       colorScheme: const ColorScheme.dark(
         background: NoirColors.black, surface: NoirColors.gray900,
         onBackground: NoirColors.white, onSurface: NoirColors.white,
         primary: NoirColors.white, secondary: NoirColors.gray200,
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

  3. test/theme_test.dart:
     import 'package:flutter_test/flutter_test.dart';
     import 'package:noir_android_app/core/theme/noir_theme.dart';
     import 'package:noir_android_app/core/constants.dart';
     void main() {
       test('NoirColors has exactly 7 colors and matches V2.1 spec', () {
         expect(NoirColors.black.value, equals(0xFF000000));
         expect(NoirColors.white.value, equals(0xFFFFFFFF));
         expect(NoirColors.gray900.value, equals(0xFF121212));
         expect(NoirColors.gray800.value, equals(0xFF1E1E1E));
         expect(NoirColors.gray700.value, equals(0xFF2A2A2A));
         expect(NoirColors.gray200.value, equals(0xFFE5E5E5));
         expect(NoirColors.gray400.value, equals(0xFFB0B0B0));
       });
       test('noirTheme uses only the 7 allowed colors', () {
         final t = noirTheme;
         expect(t.scaffoldBackgroundColor, NoirColors.black);
         expect(t.colorScheme.background, NoirColors.black);
         expect(t.colorScheme.surface, NoirColors.gray900);
         expect(t.colorScheme.onBackground, NoirColors.white);
         expect(t.colorScheme.onSurface, NoirColors.white);
         expect(t.colorScheme.primary, NoirColors.white);
         expect(t.colorScheme.secondary, NoirColors.gray200);
         expect(t.iconTheme.color, NoirColors.white);
         expect(t.dividerColor, NoirColors.gray700);
       });
     }

STEP 3 — Replace lib/main.dart (Write tool, full replacement):
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

STEP 4 — Run verification (single command):
     cd /home/santhosh/projects/Noir-Android-app && /home/santhosh/flutter/flutter/bin/flutter pub get && /home/santhosh/flutter/flutter/bin/flutter analyze && /home/santhosh/flutter/flutter/bin/flutter test test/theme_test.dart

Constraints:
  - First output = the mv command for the kotlin dir. Zero commentary.
  - DO NOT install Flutter, DO NOT touch anything outside /home/santhosh/projects/Noir-Android-app
  - DO NOT run flutter build apk (only analyze + test)
  - Batch all file writes in one tool-call block where possible

Self-review (mandatory): re-read your diff; run `grep -rE "0xFF[0-9A-Fa-f]{6}" lib/ test/ | grep -vE "0xFF(000000|FFFFFF|121212|1E1E1E|2A2A2A|E5E5E5|B0B0B0)"` — must be EMPTY; run `grep -r "com.noir.noir_android_app" android/` — must be EMPTY; run verification command yourself; report files + test pass/fail + risks. STOP.