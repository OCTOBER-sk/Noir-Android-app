import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/safety/policy_engine.dart';

void main() {
  group('PolicyEngine', () {
    test('returns a meaningful String confirmation for a valid proposal', () {
      final result = PolicyEngine().gate(<String, dynamic>{
        'action': 'save_fact',
        'input': 'remember this',
      });

      expect(result.allowed, isTrue);
      expect(result.message, isA<String>());
      expect(result.message.trim(), isNotEmpty);
      expect(result.message, contains('save_fact'));
      expect(result.needsConfirmation, isTrue);
      expect(result.needsBiometric, isFalse);
    });

    test('requires biometric confirmation for risk level 2 or higher', () {
      final engine = PolicyEngine();

      for (final riskLevel in [2, 3]) {
        final result = engine.gate(<String, dynamic>{
          'action': 'send',
          'input': 'person@example.com',
        }, riskLevel: riskLevel);

        expect(result.allowed, isTrue);
        expect(result.message, contains('send'));
        expect(result.needsConfirmation, isTrue);
        expect(result.needsBiometric, isTrue);
      }

      final lowRisk = engine.gate(<String, dynamic>{'action': 'save_fact'});
      expect(lowRisk.needsBiometric, isFalse);
      expect(engine.requireBiometric, isFalse);
    });

    test('blocks malformed proposals without throwing', () {
      final engine = PolicyEngine();
      final malformedProposals = <dynamic>[
        null,
        'save_fact',
        42,
        <String, dynamic>{},
        <String, dynamic>{'action': ''},
        <String, dynamic>{'action': '   '},
        <String, dynamic>{'action': 42},
        <String, dynamic>{'action': null},
      ];

      for (final proposal in malformedProposals) {
        expect(() => engine.gate(proposal), returnsNormally);
        final result = engine.gate(proposal);
        expect(result.allowed, isFalse);
        expect(result.message, 'MALFORMED_PROPOSAL');
        expect(result.needsConfirmation, isFalse);
        expect(result.needsBiometric, isFalse);
      }
    });

    test('keeps UI lock and blacklist decisions fail-closed', () {
      final engine = PolicyEngine()
        ..blacklist.add('exfiltrate_screen')
        ..uiLock = true;

      final locked = engine.gate(<String, dynamic>{'action': 'send'});
      expect(locked.allowed, isFalse);
      expect(locked.message, 'UI_LOCK');
      expect(locked.needsConfirmation, isFalse);
      expect(locked.needsBiometric, isFalse);

      engine.uiLock = false;
      final blacklisted = engine.gate(<String, dynamic>{
        'action': 'exfiltrate_screen',
      }, riskLevel: 3);
      expect(blacklisted.allowed, isFalse);
      expect(blacklisted.message, 'BLACKLIST');
      expect(blacklisted.needsConfirmation, isFalse);
      expect(blacklisted.needsBiometric, isFalse);
    });
  });
}
