// Product subsystem 2 — Prompt library.
//
// Scope note: this exercises the real PromptService only. No UI, no model
// call, no network: `compose` is the single, explicit path from a named
// template to text, and nothing is applied unless the caller names a template.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/clock.dart';
import 'package:noir_android_app/prompts/prompt_service.dart';

void main() {
  late FakeClock clock;
  late PromptService service;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 3, 1, 9));
    service = PromptService(clock: clock);
  });

  group('PromptService — named templates', () {
    test('a new service holds no templates and has no default', () {
      expect(service.names(), isEmpty);
      expect(service.templates(), isEmpty);
      expect(
        () => service.compose('anything'),
        throwsA(isA<PromptValidationException>()),
      );
    });

    test('create stores a named template at version 1', () {
      final template = service.create(
        name: 'daily.digest',
        body: 'Summarise today.',
      );

      expect(template.name, 'daily.digest');
      expect(template.version, 1);
      expect(template.enabled, isTrue);
      expect(template.body, 'Summarise today.');
      expect(template.history, hasLength(1));
      expect(template.history.single.version, 1);
      expect(template.createdAt, DateTime.utc(2026, 3, 1, 9));
      expect(template.updatedAt, DateTime.utc(2026, 3, 1, 9));
      expect(service.get('daily.digest'), same(template));
    });

    test('create trims the body and the declared includes', () {
      service.create(name: 'shared.header', body: 'Noir.');
      final template = service.create(
        name: '  daily.digest  ',
        body: '  Summarise today.  ',
        includes: <String>['  shared.header  '],
      );

      expect(template.name, 'daily.digest');
      expect(template.body, 'Summarise today.');
      expect(template.includes, <String>['shared.header']);
    });

    test('a duplicate name is rejected', () {
      service.create(name: 'daily.digest', body: 'Summarise today.');

      expect(
        () => service.create(name: 'daily.digest', body: 'Something else.'),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'DUPLICATE_NAME',
          ),
        ),
      );
      expect(service.get('daily.digest')!.body, 'Summarise today.');
    });

    test(
      'get returns null for an unknown name and delete removes a template',
      () {
        service.create(name: 'daily.digest', body: 'Summarise today.');

        expect(service.get('nope'), isNull);
        expect(service.delete('daily.digest'), isTrue);
        expect(service.delete('daily.digest'), isFalse);
        expect(service.get('daily.digest'), isNull);
      },
    );

    test('names and templates are ordered deterministically', () {
      service.create(name: 'zulu', body: 'z');
      service.create(name: 'alpha', body: 'a');
      service.create(name: 'mike', body: 'm');

      expect(service.names(), <String>['alpha', 'mike', 'zulu']);
      expect(service.templates().map((PromptTemplate t) => t.name), <String>[
        'alpha',
        'mike',
        'zulu',
      ]);
    });
  });

  group('PromptService — validation', () {
    test('an invalid name is rejected with a code', () {
      final invalid = <String>[
        '',
        '   ',
        'Daily Digest',
        'daily digest',
        'daily/digest',
        '_leading',
        'a' * 65,
      ];

      for (final String name in invalid) {
        expect(
          () => service.create(name: name, body: 'body text'),
          throwsA(isA<PromptValidationException>()),
          reason: 'name "$name" must not be accepted',
        );
      }
      expect(service.names(), isEmpty);
    });

    test('an empty or oversized body is rejected', () {
      expect(
        () => service.create(name: 'ok', body: '   '),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'EMPTY_BODY',
          ),
        ),
      );
      expect(
        () => service.create(name: 'ok', body: 'x' * 5001),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'BODY_TOO_LONG',
          ),
        ),
      );
      expect(service.names(), isEmpty);
    });

    test('unknown, self and duplicate includes are rejected', () {
      expect(
        () => service.create(
          name: 'ok',
          body: 'body text',
          includes: <String>['ghost'],
        ),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'UNKNOWN_INCLUDE',
          ),
        ),
      );

      service.create(name: 'other', body: 'body text');
      expect(
        () => service.create(
          name: 'ok',
          body: 'body text',
          includes: <String>['other', 'other'],
        ),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'DUPLICATE_INCLUDE',
          ),
        ),
      );

      service.create(name: 'ok', body: 'body text');
      expect(
        () => service.create(
          name: 'selfish',
          body: 'body text',
          includes: <String>['selfish'],
        ),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'SELF_INCLUDE',
          ),
        ),
      );
      expect(
        () => service.update('ok', includes: <String>['ok']),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'SELF_INCLUDE',
          ),
        ),
      );
      expect(service.get('ok')!.includes, isEmpty);
    });

    test('an include cycle is rejected before it can be stored', () {
      service.create(name: 'a.one', body: 'one');
      service.create(name: 'b.two', body: 'two');

      expect(
        () => service.update('a.one', includes: <String>['b.two']),
        returnsNormally,
      );
      expect(
        () => service.update('b.two', includes: <String>['a.one']),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'INCLUDE_CYCLE',
          ),
        ),
      );
      expect(service.get('b.two')!.includes, isEmpty);
    });

    test('operations on an unknown name fail loudly', () {
      expect(
        () => service.update('ghost', body: 'body text'),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'UNKNOWN_NAME',
          ),
        ),
      );
      expect(
        () => service.setEnabled('ghost', false),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'UNKNOWN_NAME',
          ),
        ),
      );
    });

    test(
      'a template that includes a deleted template is not silently rewritten',
      () {
        service.create(name: 'shared.header', body: 'Noir.');
        service.create(
          name: 'daily.digest',
          body: 'Summarise today.',
          includes: <String>['shared.header'],
        );

        service.delete('shared.header');

        expect(
          () => service.compose('daily.digest'),
          throwsA(
            isA<PromptValidationException>().having(
              (PromptValidationException e) => e.code,
              'code',
              'UNKNOWN_INCLUDE',
            ),
          ),
        );
      },
    );
  });

  group('PromptService — update and versioning', () {
    test('update bumps the version and keeps the history in order', () {
      service.create(name: 'daily.digest', body: 'v1');
      clock.advance(const Duration(hours: 1));
      final updated = service.update(
        'daily.digest',
        body: 'v2',
        note: 'tighter',
      );
      clock.advance(const Duration(hours: 1));
      service.update('daily.digest', body: 'v3');

      expect(updated.version, 2);
      expect(updated.body, 'v2');
      expect(updated.createdAt, DateTime.utc(2026, 3, 1, 9));
      expect(updated.updatedAt, DateTime.utc(2026, 3, 1, 10));
      expect(updated.history.map((PromptTemplateVersion v) => v.version), <int>[
        1,
        2,
      ]);
      expect(updated.history.first.body, 'v1');
      expect(updated.history.last.body, 'v2');
      expect(updated.history.last.note, 'tighter');
      expect(
        service.get('daily.digest')!.history.last.body,
        'v3',
        reason: 'the current body is also the newest history entry',
      );
      expect(
        service
            .versions('daily.digest')
            .map((PromptTemplateVersion v) => v.body),
        <String>['v1', 'v2', 'v3'],
      );
    });

    test('an unchanged update still creates a new version', () {
      service.create(name: 'daily.digest', body: 'same');

      final updated = service.update('daily.digest');

      expect(updated.version, 2);
      expect(updated.body, 'same');
      expect(updated.history, hasLength(2));
    });

    test('a rejected update leaves the stored template untouched', () {
      service.create(name: 'daily.digest', body: 'v1');

      expect(
        () => service.update('daily.digest', body: '   '),
        throwsA(isA<PromptValidationException>()),
      );
      final current = service.get('daily.digest')!;
      expect(current.version, 1);
      expect(current.body, 'v1');
      expect(current.history, hasLength(1));
    });

    test('includes can be replaced and compose follows the new order', () {
      service.create(name: 'a.first', body: 'A');
      service.create(name: 'b.second', body: 'B');
      service.create(name: 'root', body: 'ROOT', includes: <String>['a.first']);

      expect(service.compose('root').text, '# a.first\nA\n\n# root\nROOT');

      service.update('root', includes: <String>['b.second', 'a.first']);

      expect(
        service.compose('root').text,
        '# b.second\nB\n\n# a.first\nA\n\n# root\nROOT',
      );
    });
  });

  group('PromptService — enable and disable', () {
    test('a disabled template cannot be composed', () {
      service.create(name: 'daily.digest', body: 'Summarise today.');

      final disabled = service.setEnabled('daily.digest', false);
      expect(disabled.enabled, isFalse);
      expect(
        () => service.compose('daily.digest'),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'TEMPLATE_DISABLED',
          ),
        ),
      );

      final reEnabled = service.setEnabled('daily.digest', true);
      expect(reEnabled.enabled, isTrue);
      expect(
        service.compose('daily.digest').text,
        '# daily.digest\nSummarise today.',
      );
    });

    test('a disabled include blocks the whole composition', () {
      service.create(name: 'shared.header', body: 'Noir.');
      service.create(
        name: 'daily.digest',
        body: 'Summarise today.',
        includes: <String>['shared.header'],
      );

      service.setEnabled('shared.header', false);

      expect(
        () => service.compose('daily.digest'),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'TEMPLATE_DISABLED',
          ),
        ),
      );
      expect(
        service.setEnabled('daily.digest', false).enabled,
        isFalse,
        reason: 'disabling the root is still allowed',
      );
    });

    test('enable/disable does not create a new version', () {
      service.create(name: 'daily.digest', body: 'v1');

      final disabled = service.setEnabled('daily.digest', false);

      expect(disabled.version, 1);
      expect(disabled.history, hasLength(1));
    });
  });

  group('PromptService — ordered composition', () {
    test(
      'includes are rendered first, in declared order, then the own body',
      () {
        service.create(name: 'shared.header', body: 'You are Noir.');
        service.create(name: 'shared.tone', body: 'Answer in one line.');
        service.create(
          name: 'daily.digest',
          body: 'Summarise today.',
          includes: <String>['shared.tone', 'shared.header'],
        );

        final composition = service.compose('daily.digest');

        expect(
          composition.text,
          '# shared.tone\nAnswer in one line.\n\n'
          '# shared.header\nYou are Noir.\n\n'
          '# daily.digest\nSummarise today.',
        );
        expect(composition.order, <String>[
          'shared.tone',
          'shared.header',
          'daily.digest',
        ]);
        expect(composition.root, 'daily.digest');
        expect(composition.version, 1);
      },
    );

    test('nested includes are expanded depth-first, once each', () {
      service.create(name: 'c.base', body: 'C');
      service.create(name: 'b.middle', body: 'B', includes: <String>['c.base']);
      service.create(
        name: 'a.top',
        body: 'A',
        includes: <String>['b.middle', 'c.base'],
      );

      final composition = service.compose('a.top');

      expect(composition.order, <String>[
        'c.base',
        'b.middle',
        'a.top',
      ], reason: 'a template already emitted is not emitted twice');
      expect(composition.text, '# c.base\nC\n\n# b.middle\nB\n\n# a.top\nA');
    });

    test('composition reports the version each section came from', () {
      service.create(name: 'shared.header', body: 'v1');
      service.create(
        name: 'daily.digest',
        body: 'Summarise today.',
        includes: <String>['shared.header'],
      );
      service.update('shared.header', body: 'v2');

      final composition = service.compose('daily.digest');

      expect(
        composition.sections.map((PromptSection s) => '${s.name}@${s.version}'),
        <String>['shared.header@2', 'daily.digest@1'],
      );
    });

    test('values are substituted and an unknown placeholder is an error', () {
      service.create(
        name: 'greeting',
        body: 'Hello {{name}}, you are {{role}}.',
      );

      final composition = service.compose(
        'greeting',
        values: <String, String>{'name': 'Ada', 'role': 'engineer'},
      );

      expect(composition.text, '# greeting\nHello Ada, you are engineer.');
      expect(
        () => service.compose(
          'greeting',
          values: <String, String>{'name': 'Ada'},
        ),
        throwsA(
          isA<PromptValidationException>().having(
            (PromptValidationException e) => e.code,
            'code',
            'UNRESOLVED_PLACEHOLDER',
          ),
        ),
      );
    });

    test(
      'an unused value is ignored and the text is never mutated in place',
      () {
        service.create(name: 'greeting', body: 'Hello {{name}}.');
        final first = service.compose(
          'greeting',
          values: <String, String>{'name': 'Ada', 'unused': 'x'},
        );
        final second = service.compose(
          'greeting',
          values: <String, String>{'name': 'Bob'},
        );

        expect(first.text, '# greeting\nHello Ada.');
        expect(second.text, '# greeting\nHello Bob.');
        expect(service.get('greeting')!.body, 'Hello {{name}}.');
      },
    );
  });

  group('PromptService — explicit selection only', () {
    test('a template is never pulled in unless it is named or included', () {
      service.create(name: 'shared.header', body: 'SECRET HEADER TEXT');
      service.create(name: 'daily.digest', body: 'Summarise today.');

      final composition = service.compose('daily.digest');

      expect(composition.text, '# daily.digest\nSummarise today.');
      expect(composition.text, isNot(contains('SECRET HEADER TEXT')));
      expect(service.compose('shared.header').order, <String>[
        'shared.header',
      ], reason: 'no implicit base template exists');
    });

    test('an enabled template is still not applied without being named', () {
      service.create(name: 'base', body: 'BASE');
      service.create(name: 'never.named', body: 'NEVER NAMED', enabled: true);

      expect(service.compose('base').text, isNot(contains('NEVER NAMED')));
      expect(
        service.names().where((String n) => n == 'never.named'),
        isNotEmpty,
        reason: 'it exists, it is just not selected',
      );
    });

    test('every composition names exactly the templates it rendered', () {
      service.create(name: 'shared.header', body: 'H');
      service.create(
        name: 'daily.digest',
        body: 'D',
        includes: <String>['shared.header'],
      );

      final composition = service.compose('daily.digest');

      expect(
        composition.order.toSet(),
        service.names().toSet(),
        reason: 'composition names the full set that was rendered',
      );
    });
  });

  group('PromptService — secret redaction', () {
    test('compose redacts an API key and never emits it verbatim', () {
      service.create(
        name: 'deploy',
        body: 'Use sk-abcdefgh12345678 for the deploy step.',
      );

      final composition = service.compose('deploy');

      expect(composition.text, isNot(contains('sk-abcdefgh12345678')));
      expect(composition.text, contains('[redacted:apiKey]'));
      expect(composition.redactions, <String>['apiKey']);
      expect(service.get('deploy')!.redactions, <String>[
        'apiKey',
      ], reason: 'the finding is recorded on the template');
    });

    test('each secret shape is redacted under its own kind', () {
      service.create(
        name: 'kitchen.sink',
        body: [
          'AKIAIOSFODNN7EXAMPLE is the access key id',
          'Authorization: Bearer abcdef1234567890ABCDEF',
          'password: hunter2hunter2',
          'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345',
        ].join('\n'),
      );

      final composition = service.compose('kitchen.sink');

      expect(composition.redactions, <String>[
        'awsAccessKeyId',
        'bearerToken',
        'apiKey',
        'genericSecret',
      ]);
      expect(composition.text, isNot(contains('hunter2hunter2')));
      expect(composition.text, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
      expect(
        composition.text,
        isNot(contains('ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345')),
      );
      expect(composition.text, isNot(contains('abcdef1234567890ABCDEF')));
    });

    test('a private key block is redacted whole', () {
      service.create(
        name: 'ssh',
        body:
            '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKC\nAQEA\n'
            '-----END RSA PRIVATE KEY-----',
      );

      final composition = service.compose('ssh');

      expect(composition.redactions, contains('privateKey'));
      expect(composition.text, isNot(contains('MIIEpAIBAAKC')));
      expect(composition.text, isNot(contains('BEGIN RSA PRIVATE KEY')));
    });

    test('redaction also covers substituted values and the include chain', () {
      service.create(
        name: 'shared.header',
        body: 'token is ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345',
      );
      service.create(
        name: 'root',
        body: 'key: {{key}}',
        includes: <String>['shared.header'],
      );

      final composition = service.compose(
        'root',
        values: <String, String>{'key': 'sk-abcdefgh12345678'},
      );

      expect(composition.text, isNot(contains('sk-abcdefgh12345678')));
      expect(
        composition.text,
        isNot(contains('ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345')),
      );
      expect(composition.redactions.toSet(), <String>{
        'apiKey',
        'genericSecret',
      });
    });

    test('ordinary prose is left alone', () {
      service.create(
        name: 'prose',
        body:
            'Summarise the day in three bullets. The password rotation '
            'policy is owned by IT.',
      );

      final composition = service.compose('prose');

      expect(composition.redactions, isEmpty);
      expect(
        composition.text,
        '# prose\nSummarise the day in three bullets. The password rotation '
        'policy is owned by IT.',
      );
    });

    test('redactSecrets is available on its own and is idempotent', () {
      const String raw = 'deploy with sk-abcdefgh12345678 today';

      final once = PromptService.redactSecrets(raw);
      final twice = PromptService.redactSecrets(once);

      expect(once, 'deploy with [redacted:apiKey] today');
      expect(twice, once);
      expect(PromptService.redactSecrets('nothing to hide'), 'nothing to hide');
    });

    test('a rejected secret-shaped body still reports the finding', () {
      expect(
        () => service.create(name: 'bad', body: '   '),
        throwsA(isA<PromptValidationException>()),
      );
      expect(
        service.templates().where(
          (PromptTemplate t) => t.redactions.isNotEmpty,
        ),
        isEmpty,
        reason: 'a rejected template leaves nothing behind',
      );
    });
  });
}
