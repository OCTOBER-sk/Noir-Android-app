// test/accessibility_declaration_test.dart — the guard for the two XML files
// that decide whether the accessibility bridge can work at all.
//
// The failure mode this test exists to stop is invisible to every other gate in
// this repo. `android/app/src/main/AndroidManifest.xml` and
// `android/app/src/main/res/xml/accessibility_service_config.xml` are read by
// the Android platform at *install* time, not by the Dart VM and not by the
// Kotlin unit-test source set:
//
//   - `flutter analyze` never opens them; they are not Dart.
//   - `flutter test` never opens them; the Dart side talks to the service
//     through a MethodChannel whose payloads the tests synthesise themselves.
//   - `android/.../testDebugUnitTest` compiles and runs the Kotlin helpers, but
//     GestureGateTest.kt only asserts a hard-coded constant standing in for the
//     capability bit; it never reads the config that sets it.
//   - `flutter build apk --debug` packages whatever it finds. Deleting the
//     capability attribute produces a *successfully built* APK that cannot
//     dispatch a single gesture.
//
// So a one-line regression in either file yields a green CI run, every Dart test
// passing, a green Kotlin suite, and a shipped app whose every tap silently
// fails with GESTURE_DISPATCH_REJECTED — the exact failure the config file's
// own header comment warns about ("the platform does not assume this — it reads
// CAPABILITY_CAN_PERFORM_GESTURES at dispatch time and fails closed").
//
// These assertions therefore encode the platform contract, not a snapshot of
// today's file. Each cites the reason it exists so a later edit that looks like a
// tidy-up can tell it is removing a load-bearing declaration.
//
// Scope note, deliberately: this asserts the *declaration* is present and
// correct. It is not a substitute for observing the bridge on hardware. Nothing
// in this repository — test or CI — has ever run on a device or emulator, and
// these assertions must never be reported as evidence that it has.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';
const String kServiceConfigPath =
    'android/app/src/main/res/xml/accessibility_service_config.xml';
const String kStringsPath = 'android/app/src/main/res/values/strings.xml';

/// The package root: the nearest ancestor of the test working directory that
/// holds a `pubspec.yaml`.
Directory _packageRoot() {
  Directory current = Directory.current.absolute;
  while (true) {
    if (File('${current.path}/pubspec.yaml').existsSync()) return current;
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('no pubspec.yaml found above ${current.path}');
    }
    current = parent;
  }
}

/// The raw text of a file that must exist for the app to build at all.
String _read(Directory root, String relativePath) {
  final File file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('required file is missing: $relativePath');
  }
  return file.readAsStringSync();
}

/// [source] with every XML comment removed. Comments are not nested here.
///
/// This is load-bearing, not cosmetic. Both files carry long explanatory header
/// comments that quote the very attributes under assertion — the manifest
/// comment says `android:permission="BIND_ACCESSIBILITY_SERVICE"`, and the
/// config comment quotes `CAPABILITY_CAN_PERFORM_GESTURES`. A whole-file regex
/// happily matches that prose and then reports the comment's shortened form as
/// the file's value, which fails for a reason unrelated to the declaration under
/// test. Every lookup below runs against stripped text so a failure always
/// points at the element.
String _stripComments(String source) =>
    source.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// The opening tag of the first `<name ...>` element in [source], or null.
String? _element(String source, String name) =>
    RegExp('<$name\\b[^>]*>').firstMatch(source)?.group(0);

/// The value of `attribute="value"` inside [source], or null when absent.
///
/// [attribute] is regex-escaped so a dotted attribute name matches literally
/// rather than as a pattern.
String? _attribute(String source, String attribute) => RegExp(
  '${RegExp.escape(attribute)}\\s*=\\s*"([^"]*)"',
).firstMatch(source)?.group(1);

/// Every `<uses-permission android:name="...">` value in [source].
List<String> _declaredPermissions(String source) => RegExp(
  r'<uses-permission\s+android:name="([^"]*)"',
).allMatches(source).map((RegExpMatch m) => m.group(1)!).toList();

void main() {
  late Directory root;
  late String manifest;
  late String serviceConfig;
  late String? serviceElement;

  setUpAll(() {
    root = _packageRoot();
    manifest = _stripComments(_read(root, kManifestPath));
    serviceConfig = _stripComments(_read(root, kServiceConfigPath));
    serviceElement = _element(manifest, 'service');
  });

  group('the accessibility service is declared', () {
    test('the manifest registers .AgentAccessibilityService', () {
      // Without this <service> element Settings cannot bind anything at all, so
      // every status read reports "not connected" no matter what the user does.
      expect(
        serviceElement,
        isNotNull,
        reason:
            'AndroidManifest.xml must contain a <service> element. Without one '
            'the Dart status layer reports a disconnected service '
            'indistinguishably from the user never having enabled it.',
      );
      expect(
        _attribute(serviceElement!, 'android:name'),
        '.AgentAccessibilityService',
        reason:
            'the <service> must name .AgentAccessibilityService, the class '
            'MainActivity installs its runtime sink on.',
      );
    });

    test('the service is bound only by the system', () {
      // BIND_ACCESSIBILITY_SERVICE is a signature-level permission. On the
      // <service> it is what restricts binding to the platform; as a
      // <uses-permission> it is a no-op. exported="true" is required *because*
      // the permission is what does the restricting.
      expect(
        _attribute(serviceElement!, 'android:permission'),
        'android.permission.BIND_ACCESSIBILITY_SERVICE',
        reason:
            'the <service> must carry android:permission='
            '"android.permission.BIND_ACCESSIBILITY_SERVICE". As a '
            '<uses-permission> this permission does nothing; on the element it '
            'is the only thing restricting binding to the system.',
      );
      expect(
        _attribute(serviceElement!, 'android:exported'),
        'true',
        reason:
            'the <service> must be exported="true" so Settings can bind it. '
            'The permission attribute, not export state, is what keeps it safe.',
      );
      expect(
        _declaredPermissions(manifest),
        isNot(contains('android.permission.BIND_ACCESSIBILITY_SERVICE')),
        reason:
            'BIND_ACCESSIBILITY_SERVICE must not be declared as a '
            '<uses-permission>; that declaration is a no-op and misstates the '
            "app's permission surface.",
      );
    });

    test('the service points at its config resource', () {
      expect(
        manifest,
        contains('android:resource="@xml/accessibility_service_config"'),
        reason:
            'the <service> must carry accessibilityservice meta-data naming '
            '@xml/accessibility_service_config. Without it the platform loads '
            'default capabilities: no gesture dispatch, and rootInActiveWindow '
            'returns null.',
      );
    });
  });

  group('the service config grants the capabilities the code depends on', () {
    test('canPerformGestures is true', () {
      // The single most load-bearing attribute in the repository. The platform
      // reads CAPABILITY_CAN_PERFORM_GESTURES at dispatch time and fails closed
      // when the bit is absent, so removing or flipping this turns every
      // MainActivity.executeGesture() call into GESTURE_DISPATCH_REJECTED while
      // the whole Dart suite still passes.
      expect(
        _attribute(serviceConfig, 'android:canPerformGestures'),
        'true',
        reason:
            'android:canPerformGestures="true" is REQUIRED in '
            '$kServiceConfigPath. Without it AccessibilityService.'
            'dispatchGesture() always returns false and every gesture fails '
            'closed with GESTURE_DISPATCH_REJECTED — with no test or CI step '
            'anywhere in this repo able to see it.',
      );
    });

    test('canRetrieveWindowContent is true', () {
      // Required for rootInActiveWindow, the only source of the node tree the
      // agent reasons over. Without it every dump is empty.
      expect(
        _attribute(serviceConfig, 'android:canRetrieveWindowContent'),
        'true',
        reason:
            'android:canRetrieveWindowContent="true" is required for '
            'rootInActiveWindow, the only source of the node tree the agent '
            'reasons over. Absent it, every screen dump is empty while the '
            'bridge still reports itself connected.',
      );
    });

    test('flagReportViewIds is set', () {
      // viewIdResourceName is how a node gets a stable identity across dumps.
      // Without the flag that field is null and node identity degrades to
      // geometry alone.
      expect(
        _attribute(serviceConfig, 'android:accessibilityFlags'),
        contains('flagReportViewIds'),
        reason:
            'android:accessibilityFlags must include flagReportViewIds so '
            'viewIdResourceName is populated and a node has an identity that is '
            'not just its geometry.',
      );
    });

    test('isAccessibilityTool is declared false explicitly', () {
      // The service automates the user's own device for an app-driven workflow;
      // it is not an assistive technology. Play requires that to be stated, not
      // defaulted.
      expect(
        _attribute(serviceConfig, 'android:isAccessibilityTool'),
        'false',
        reason:
            'android:isAccessibilityTool="false" must be stated explicitly. '
            "Noir drives the user's own device for an app workflow and is not "
            'an assistive technology; the Play policy for that class of service '
            'requires the declaration rather than a default.',
      );
    });

    test('the user-facing description string is defined', () {
      // The config references @string/accessibility_service_description. A
      // missing resource is a resource-linking failure that surfaces only at
      // `flutter build apk`, and this string is a Play policy disclosure — a
      // rename that silently dropped it would ship with no disclosure at all.
      final String strings = _stripComments(_read(root, kStringsPath));
      final String? descriptionRef = _attribute(
        serviceConfig,
        'android:description',
      );
      expect(
        descriptionRef,
        isNotNull,
        reason: 'the config must carry android:description.',
      );
      final String name = descriptionRef!.replaceFirst('@string/', '');
      expect(
        strings,
        contains('name="$name"'),
        reason:
            'the config references @string/$name but $kStringsPath defines no '
            'string with that name, so the APK has no user-facing disclosure of '
            'what the service collects and when it acts.',
      );
    });
  });

  group('the declared permissions match what the code uses', () {
    test('INTERNET is the only uses-permission declared', () {
      // An extra permission is a false claim on the app's permission surface.
      // The manifest header already records why ACCESS_NETWORK_STATE and
      // USE_BIOMETRIC are deliberately absent; this makes that a gate.
      expect(
        _declaredPermissions(manifest),
        <String>['android.permission.INTERNET'],
        reason:
            'only android.permission.INTERNET is implemented. Additional '
            "declared permissions would be a false claim on the app's "
            'permission surface: there is no native connectivity probe and the '
            'native BiometricPrompt flow is not implemented.',
      );
    });

    test('cleartext traffic stays disabled', () {
      expect(
        _attribute(manifest, 'android:usesCleartextTraffic'),
        'false',
        reason:
            'android:usesCleartextTraffic="false" must stay on the '
            '<application>. Noir talks to model endpoints over TLS; allowing '
            'cleartext would widen the surface without a caller.',
      );
    });

    test('every @xml and @string resource the manifest names resolves', () {
      // Whole-file sweep so a renamed resource cannot leave a dangling
      // reference that only `flutter build apk` would notice.
      //
      // The two reference kinds resolve differently and conflating them was
      // this test's own first-draft bug: `@string/app_name` is an entry
      // *inside* every values*/strings.xml, not a file named app_name.xml, so
      // the file-shaped lookup reported a real, correctly-declared string as
      // missing. `@xml/...` really is one file per name, but a values-night
      // qualifier may also supply it, so both forms scan the directory.
      final List<String> references = RegExp(
        r'@xml/[A-Za-z0-9_]+|@string/[A-Za-z0-9_]+',
      ).allMatches(manifest).map((RegExpMatch m) => m.group(0)!).toList();
      expect(references, isNotEmpty, reason: 'expected at least one reference');

      for (final String reference in references) {
        final List<String> parts = reference.split('/');
        final String kind = parts.first.substring(1);
        final String name = parts.last;
        if (kind == 'xml') {
          final Directory xmlDir = Directory(
            '${root.path}/android/app/src/main/res/xml',
          );
          final bool found =
              !xmlDir.existsSync() ||
              xmlDir.listSync().whereType<File>().any(
                (File f) => f.path.split('/').last == '$name.xml',
              );
          expect(
            found,
            isTrue,
            reason:
                '$reference is named in the manifest but no xml/$name.xml '
                'exists, so resource linking fails at `flutter build apk`.',
          );
        } else {
          // A string may live in any qualified values-* directory, and a
          // night-only string still links against an unqualified reference.
          final List<File> valueFiles =
              Directory('${root.path}/android/app/src/main/res')
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where(
                    (File f) =>
                        f.path.contains('/values') &&
                        f.path.endsWith('/strings.xml'),
                  )
                  .toList();
          expect(
            valueFiles.any(
              (File f) => f.readAsStringSync().contains('name="$name"'),
            ),
            isTrue,
            reason:
                '$reference is named in the manifest but no values*/strings.xml '
                'declares a string named "$name", so the APK carries no such '
                'resource and resource linking fails at `flutter build apk`.',
          );
        }
      }
    });
  });

  group('the guard itself has teeth', () {
    test('a config missing canPerformGestures is detected', () {
      // Proves the assertion above is not vacuously true. The defect guarded
      // here is invisible to every other gate in the repo, so a guard that
      // cannot fail is worse than no guard.
      const String stripped =
          '<accessibility-service '
          'android:canRetrieveWindowContent="true" '
          'android:isAccessibilityTool="false" />';
      expect(
        _attribute(stripped, 'android:canPerformGestures'),
        isNot('true'),
        reason:
            'the lookup must report a config with no canPerformGestures '
            'attribute as non-conformant',
      );
      expect(
        _attribute(stripped, 'android:canRetrieveWindowContent'),
        'true',
        reason:
            'the same lookup must still read the attributes that are present, '
            'so a failure above identifies the missing bit rather than a parser '
            'that stopped working',
      );
    });

    test('a manifest whose comment quotes the attribute is not misread', () {
      // The regression this file's own first draft had: matching the comment's
      // `android:permission="BIND_ACCESSIBILITY_SERVICE"` instead of the
      // element's fully-qualified value. Comments must not be read as
      // declarations, or this whole file asserts on prose.
      const String withComment =
          '<!-- see android:permission="BIND_ACCESSIBILITY_SERVICE" -->'
          '<service android:name=".X" '
          'android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE" />';
      expect(
        _attribute(_stripComments(withComment), 'android:permission'),
        'android.permission.BIND_ACCESSIBILITY_SERVICE',
        reason:
            "after stripping comments the element value must win over the "
            "comment's shorthand",
      );
    });

    test('a manifest that re-declares the bind permission is detected', () {
      const String bad =
          '<uses-permission '
          'android:name="android.permission.BIND_ACCESSIBILITY_SERVICE" />';
      expect(
        _declaredPermissions(bad),
        contains('android.permission.BIND_ACCESSIBILITY_SERVICE'),
        reason: 'the uses-permission scan must see the forbidden declaration',
      );
      expect(
        _declaredPermissions(manifest),
        isNot(contains('android.permission.BIND_ACCESSIBILITY_SERVICE')),
        reason: 'and the real manifest must not contain it',
      );
    });

    test('the real service element is the one the assertions read', () {
      // Ties the scoped lookup back to the file: if the element were ever
      // renamed or the manifest restructured, serviceElement goes null and the
      // group above fails with a message about the missing declaration rather
      // than about a silently-empty string.
      expect(serviceElement, isNotNull);
      expect(serviceElement, startsWith('<service'));
      expect(serviceElement, endsWith('>'));
    });
  });
}
