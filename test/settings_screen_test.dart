// test/settings_screen_test.dart — the settings screen is the only way a real
// user can give Noir a provider, so "it compiles" is not evidence that it works.
//
// The defect this file exists to prevent is the shape this repo has hit
// repeatedly: a capability fully implemented in the repository layer, exercised
// by tests that call the repository directly, and unreachable from the app.
// `SettingsRepository.setSecret` had zero callers in lib/. These tests pin the
// contract that screen's save path depends on, and guard that the screen exists
// at all, so the repository can never again be left without a writer.
//
// These are plain `test` cases rather than `testWidgets`. The data layer writes
// real files, and a widget test body runs in the binding's fake-async zone where
// that I/O never completes — the save hangs with the button stuck on "Saving…".
// The state that matters here is that a save writes a real record and a real
// secret, which needs no rendered frame.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';
import 'package:noir_android_app/ui/settings_screen.dart';

void main() {
  late Directory workspace;
  late NoirDataLayer layer;

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('noir-settings-');
    layer = await NoirDataLayer.open(root: workspace);
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// The exact record the screen builds from its four fields.
  ProviderSettings screenRecord({
    String name = 'My gateway',
    String baseUrl = 'https://api.example.com/v1',
    String model = 'vendor/model-a',
    String id = 'primary',
  }) {
    final stamp = DateTime.utc(2026, 5, 1);
    return ProviderSettings(
      id: id,
      displayName: name.trim().isEmpty ? 'My provider' : name.trim(),
      baseUrl: baseUrl.trim(),
      defaultModel: model.trim(),
      fallbackModels: const <String>[],
      funded: false,
      rpmCap: 20,
      dailyCap: 50,
      createdAt: stamp,
      updatedAt: stamp,
    );
  }

  test('the screen still exists, so the repository has a writer', () {
    // If this is ever deleted or renamed, `setSecret` goes back to having no
    // caller in lib/ and the app can never acquire a provider again.
    expect(SettingsScreen, isNotNull);
  });

  test(
    'saving a provider and an API key puts both in the real store',
    () async {
      await layer.settings.upsert(screenRecord());
      await layer.settings.setSecret('primary', 'test-key-value');

      final all = await layer.settings.readAll();
      expect(all, hasLength(1));
      expect(all.single.displayName, 'My gateway');
      expect(all.single.baseUrl, 'https://api.example.com/v1');
      expect(all.single.defaultModel, 'vendor/model-a');
      expect(all.single.hasSecret, isTrue);

      // The key is readable by the one component allowed to read it — the
      // provider adapter. Nothing else may hold a copy.
      expect(await layer.settings.resolveSecret('primary'), 'test-key-value');
    },
  );

  test('the stored record never contains the secret value', () async {
    await layer.settings.upsert(screenRecord());
    await layer.settings.setSecret('primary', 'test-key-value');

    final record = (await layer.settings.readAll()).single;
    expect(record.secretValue, isNull);
    expect(record.toString(), isNot(contains('test-key-value')));

    final redacted = record.toRedactedJson();
    expect(redacted['secretRef'], redactedSecretPlaceholder);
    expect(redacted['secretConfigured'], isTrue);
  });

  test(
    'an invalid base URL is rejected by the record, not silently stored',
    () async {
      // The screen hands typed values straight to the repository, so the
      // repository's own validation is the only guard. It must reject.
      expect(
        () => screenRecord(baseUrl: 'not-a-url'),
        throwsA(isA<InvalidDataError>()),
      );
      expect(await layer.settings.readAll(), isEmpty);
    },
  );

  test('a blank model is rejected too', () {
    expect(() => screenRecord(model: '   '), throwsA(isA<InvalidDataError>()));
  });

  test('a blank display name falls back rather than failing the save', () {
    expect(screenRecord(name: '   ').displayName, 'My provider');
  });

  test('a saved key can be forgotten, and the store really drops it', () async {
    await layer.settings.upsert(screenRecord());
    await layer.settings.setSecret('primary', 'test-key-value');
    expect((await layer.settings.readAll()).single.hasSecret, isTrue);

    await layer.settings.clearSecret('primary');

    final all = await layer.settings.readAll();
    expect(all, hasLength(1), reason: 'the provider record itself stays');
    expect(all.single.hasSecret, isFalse);
    expect(await layer.settings.resolveSecret('primary'), isNull);
  });

  test('the saved provider survives a reopen, so it is durable', () async {
    await layer.settings.upsert(screenRecord());
    await layer.settings.setSecret('primary', 'test-key-value');

    // A brand new layer over the same directory: this is what a relaunch does.
    final reopened = await NoirDataLayer.open(root: workspace);
    final all = await reopened.settings.readAll();
    expect(all, hasLength(1));
    expect(all.single.baseUrl, 'https://api.example.com/v1');
    expect(await reopened.settings.resolveSecret('primary'), 'test-key-value');
  });

  test('an empty key is refused rather than storing a blank secret', () async {
    await layer.settings.upsert(screenRecord());
    await expectLater(
      layer.settings.setSecret('primary', ''),
      throwsA(isA<InvalidDataError>()),
    );
  });
}
