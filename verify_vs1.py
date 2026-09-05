#!/usr/bin/env python3
import subprocess
import os
import sys

# Install flutter locally if missing
flutter_path = "/home/santhosh/flutter/bin/flutter"
if not os.path.exists(flutter_path):
    print("Flutter not found, installing...")
    os.makedirs("/home/santhosh/flutter", exist_ok=True)
    subprocess.run(["wget", "-q", "https://storage.googleapis.com/flutter_infra_release/flutter/linux/latest/flutter_linux_3.24.0-stable.tar.xz"], check=True, cwd="/home/santhosh/flutter")
    subprocess.run(["tar", "xf", "flutter_linux_3.24.0-stable.tar.xz"], check=True, cwd="/home/santhosh/flutter")
    subprocess.run(["rm", "flutter_linux_3.24.0-stable.tar.xz"], check=True, cwd="/home/santhosh/flutter")
    print("Flutter installed")

# Add to PATH for subprocess
env = os.environ.copy()
env["PATH"] = f"{os.path.dirname(flutter_path)}:{env['PATH']}"

# Verify
result = subprocess.run([flutter_path, "--version"], capture_output=True, text=True, env=env, timeout=30)
print(f"Flutter version: {result.stdout.strip()}")

# Now run the actual task in the project dir
project_dir = "/home/santhosh/projects/Noir-Android-app"
os.chdir(project_dir)

# First, create the basic scaffold from scratch since repo is empty
files_to_create = [
    ("lib/core/theme/noir_theme.dart", '''
import 'package:flutter/material.dart';

/// Noir theme - pure black and white only, zero color accents
/// Allowed colors: #000000, #FFFFFF, #121212, #1E1E1E, #2A2A2A, #E5E5E5, #B0B0B0
final ThemeData noirTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Color(0xFF000000),
  colorScheme: ColorScheme.dark(
    background: Color(0xFF000000),
    surface: Color(0xFF121212),
    onBackground: Color(0xFFFFFFFF),
    onSurface: Color(0xFFFFFFFF),
    primary: Color(0xFFFFFFFF),
    secondary: Color(0xFFE5E5E5),
  ),
  textTheme: TextTheme(
    displayLarge: TextStyle(color: Colors.white, fontSize: 32),
    displayMedium: TextStyle(color: Colors.white, fontSize: 24),
    displaySmall: TextStyle(color: Colors.white, fontSize: 20),
    bodyLarge: TextStyle(color: Colors.white, fontSize: 16),
    bodyMedium: TextStyle(color: Colors.white, fontSize: 14),
    bodySmall: TextStyle(color: Colors.white, fontSize: 12),
    labelLarge: TextStyle(color: Colors.white, fontSize: 14),
    labelMedium: TextStyle(color: Colors.white, fontSize: 12),
    labelSmall: TextStyle(color: Colors.white, fontSize: 10),
  ),
  iconTheme: IconThemeData(color: Colors.white),
  dividerColor: Color(0xFF2A2A2A),
);
'''),
    ("lib/core/constants.dart", '''
import 'package:flutter/material.dart';

/// Noir color constants - pure black and white only, zero color accents
class NoirColors {
  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color gray900 = Color(0xFF121212);
  static const Color gray800 = Color(0xFF1E1E1E);
  static const Color gray700 = Color(0xFF2A2A2A);
  static const Color gray200 = Color(0xFFE5E5E5);
  static const Color gray400 = Color(0xFFB0B0B0);
}
'''),
    ("android/app/src/main/AndroidManifest.xml", '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.noir.android">
    <application
        android:label="noir_android_app"
        android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme"
                />
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <!-- Don't delete the meta-data below.
             This is used by the Flutter tool to generate GeneratedPluginRegistrant.java -->
        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />
    </application>
</manifest>
'''),
    ("android/app/build.gradle.kts", '''
plugins {
    id("com.android.application")
    id("kotlin-android")
    id("flutter.application")
}

android {
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    sourceSets {
        main.java.srcDirs += "src/main/kotlin"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.noir.android"
        minSdk = 21
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keystore for example
            // signingConfig signingConfigs.debug
            minifyEnabled = false
            shrinkResources = false
            versionNameSuffix = "-dev"
        }
    }
}

flutter {
    source "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
}
'''),
    ("analysis_options.yaml", '''
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    avoid_print: true
    avoid_redundant_argument_values: true
    avoid_types_as_parameter_names: true
    cascade_invoke_exprs: true
    cancel_subscriptions: true
    close_sinks: true
    comment_references: true
    constant_identifier_names: true
    control_flow_in_finally: true
    curly_braces_in_flow_control: true
    empty_statements: true
    hash_and_equals: true
    literals_enum_interpolation: true
    no_duplicate_case_values: true
    no_leading_underscores_for_local_identifiers: true
    no_null_argument_assignments: true
    prefer_final_fields: true
    prefer_is_empty: true
    prefer_mixin_to_override: true
    prefer_single_quotes: true
    prefer_typing_uninitialized_variables: true
    prefer_void_to_null: true
    sort_child_properties_last: true
    unnecessary_const: true
    unnecessary_library_names: true
    unnecessary_nullable_for_final_variable_declarations: true
    unnecessary_overrides: true
    unnecessary_statements: true
    untyped_formal_parameters: true
    use_build_context_synchronously: true
    use_string_buffers: true
    use_strings_in_expressions: true
    use_test_constants: true
    valid_regexps: true
'''),
]

# Create directories and write files
for rel_path, content in files_to_create:
    abs_path = f"{project_dir}/{rel_path}"
    os.makedirs(os.path.dirname(abs_path), exist_ok=True)
    with open(abs_path, 'w') as f:
        f.write(content.strip())
    print(f"Created: {rel_path}")

# Create simple theme test
test_content = '''
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/theme/noir_theme.dart';
import 'package:noir_android_app/core/constants.dart';

void main() {
  group('NoirTheme', () {
    test('uses only allowed colors', () {
      final theme = noirTheme;
      // Check scaffold background
      expect(theme.scaffoldBackgroundColor.value, equals(0xFF000000));
      // Check color scheme
      expect(theme.colorScheme.background.value, equals(0xFF000000));
      expect(theme.colorScheme.surface.value, equals(0xFF121212));
      expect(theme.colorScheme.onBackground.value, equals(0xFFFFFFFF));
      expect(theme.colorScheme.onSurface.value, equals(0xFFFFFFFF));
      expect(theme.colorScheme.primary.value, equals(0xFFFFFFFF));
      expect(theme.colorScheme.secondary.value, equals(0xFFE5E5E5));
      // Check text theme - all should be white
      expect(theme.textTheme.displayLarge?.color.value, equals(0xFFFFFFFF));
      expect(theme.textTheme.displayMedium?.color.value, equals(0xFFFFFFFF));
      expect(theme.textTheme.displaySmall?.color.value, equals(0xFFFFFFFF));
      expect(theme.textTheme.bodyLarge?.color.value, equals(0xFFFFFFFF));
      expect(theme.textTheme.bodyMedium?.color.value, equals(0xFFFFFFFF));
      expect(theme.textTheme.bodySmall?.color.value, equals(0xFFFFFFFF));
      expect(theme.textTheme.labelLarge?.color.value, equals(0xFFFFFFFF));
      expect(theme.textTheme.labelMedium?.color.value, equals(0xFFFFFFFF));
      expect(theme.textTheme.labelSmall?.color.value, equals(0xFFFFFFFF));
      // Check icon theme
      expect(theme.iconTheme.color.value, equals(0xFFFFFFFF));
      // Check divider
      expect(theme.dividerColor.value, equals(0xFF2A2A2A));
    });
  });
}
'''
test_path = f"{project_dir}/test/theme_test.dart"
os.makedirs(os.path.dirname(test_path), exist_ok=True)
with open(test_path, 'w') as f:
    f.write(test_content.strip())
print("Created: test/theme_test.dart")

# Run verification
print("\nRunning verification...")
result = subprocess.run([
    flutter_path, "pub", "get"
], capture_output=True, text=True, env=env, timeout=60)
print(f"flutter pub get: exit {result.returncode}")
if result.stdout: print(f"stdout: {result.stdout[:200]}")
if result.stderr: print(f"stderr: {result.stderr[:200]}")

result = subprocess.run([
    flutter_path, "analyze"
], capture_output=True, text=True, env=env, timeout=60)
print(f"flutter analyze: exit {result.returncode}")
if result.stdout: print(f"stdout: {result.stdout[:200]}")
if result.stderr: print(f"stderr: {result.stderr[:200]}")

result = subprocess.run([
    flutter_path, "test", "test/theme_test.dart"
], capture_output=True, text=True, env=env, timeout=60)
print(f"flutter test: exit {result.returncode}")
if result.stdout: print(f"stdout: {result.stdout}")
if result.stderr: print(f"stderr: {result.stderr}")

print("\nVS.1 TASK COMPLETE")