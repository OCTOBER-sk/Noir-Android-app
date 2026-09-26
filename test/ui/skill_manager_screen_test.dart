// test/ui/skill_manager_screen_test.dart — the Skill Manager lists only the
// SkillRecords it is handed.
//
// The three hard-coded rows (Message Triage / Form Fill / Photo Note) and the
// hard-coded "last used 2h ago" are gone: a skill that has never run says so,
// and a screen with no registry attached says that too.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/ui/skill_manager_screen.dart';

import 'fake_state_source.dart';

void main() {
  /// Fixed clock: the relative "last used" line is derived from it, so these
  /// assertions never depend on when the suite happens to run.
  final DateTime now = DateTime(2026, 1, 2, 12);

  group('SkillManagerScreen', () {
    testWidgets('is unavailable — not invented — when no source is wired', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SkillManagerScreen()));

      expect(find.text('No skill source is connected.'), findsOneWidget);
      expect(find.text('Skill Manager'), findsOneWidget);
      expect(find.text('Message Triage'), findsNothing);
      expect(find.text('Form Fill'), findsNothing);
      expect(find.text('Photo Note'), findsNothing);
      expect(find.text('last used 2h ago'), findsNothing);
    });

    testWidgets('loading resolves into the records the source reported', (
      tester,
    ) async {
      final source = FakeStateSource<SkillListState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SkillManagerScreen(source: source.stream, now: () => now),
        ),
      );
      await tester.pump();

      expect(find.text('Reading registered skills…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Message Triage'), findsNothing);

      source.emit(
        const SkillListAvailable(<SkillRecord>[
          SkillRecord(
            id: 'inbox-sweep',
            name: 'Inbox sweep',
            state: SkillState.validated,
            lastUsedAt: null,
          ),
          SkillRecord(
            id: 'receipt-capture',
            name: 'Receipt capture',
            state: SkillState.needsReview,
            lastUsedAt: null,
            detail: 'Awaiting a human review.',
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('Reading registered skills…'), findsNothing);
      expect(find.text('Inbox sweep'), findsOneWidget);
      expect(find.text('validated'), findsOneWidget);
      expect(find.text('Receipt capture'), findsOneWidget);
      expect(find.text('needs review'), findsOneWidget);
      expect(find.text('Awaiting a human review.'), findsOneWidget);
      // A skill that has never run cannot claim it ran two hours ago.
      expect(find.text('never run'), findsNWidgets(2));
      expect(find.text('last used 2h ago'), findsNothing);
    });

    testWidgets('derives the last-used line from the record timestamp', (
      tester,
    ) async {
      final source = FakeStateSource<SkillListState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SkillManagerScreen(source: source.stream, now: () => now),
        ),
      );
      source.emit(
        SkillListAvailable(<SkillRecord>[
          SkillRecord(
            id: 'inbox-sweep',
            name: 'Inbox sweep',
            state: SkillState.active,
            lastUsedAt: now.subtract(const Duration(hours: 2)),
          ),
          SkillRecord(
            id: 'older',
            name: 'Older skill',
            state: SkillState.disabled,
            lastUsedAt: now.subtract(const Duration(days: 3)),
          ),
          SkillRecord(
            id: 'fresh',
            name: 'Fresh skill',
            state: SkillState.active,
            lastUsedAt: now.subtract(const Duration(seconds: 20)),
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('last used 2h ago'), findsOneWidget);
      expect(find.text('last used 3d ago'), findsOneWidget);
      expect(find.text('last used <1m ago'), findsOneWidget);
      expect(find.text('disabled'), findsOneWidget);
    });

    testWidgets('an empty registry is empty, not three sample rows', (
      tester,
    ) async {
      final source = FakeStateSource<SkillListState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SkillManagerScreen(source: source.stream, now: () => now),
        ),
      );
      source.emit(const SkillListAvailable(<SkillRecord>[]));
      await tester.pump();

      expect(find.text('No skills are registered.'), findsOneWidget);
      expect(find.text('Message Triage'), findsNothing);
    });

    testWidgets('a failure shows the reason and retries only on demand', (
      tester,
    ) async {
      final source = FakeStateSource<SkillListState>();
      addTearDown(source.close);
      var retries = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SkillManagerScreen(
            source: source.stream,
            now: () => now,
            onRetry: () => retries++,
          ),
        ),
      );
      source.emit(const SkillListFailed('Skill registry unreachable.'));
      await tester.pump();

      expect(find.text('Skill registry unreachable.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Message Triage'), findsNothing);
      expect(retries, 0);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(retries, 1);
    });

    testWidgets('a throwing source degrades to a failure state', (
      tester,
    ) async {
      final source = FakeStateSource<SkillListState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SkillManagerScreen(source: source.stream, now: () => now),
        ),
      );
      source.fail(StateError('registry socket closed'));
      await tester.pump();

      expect(find.textContaining('registry socket closed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a later emission replaces the records already listed', (
      tester,
    ) async {
      final source = FakeStateSource<SkillListState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SkillManagerScreen(source: source.stream, now: () => now),
        ),
      );
      source.emit(
        const SkillListAvailable(<SkillRecord>[
          SkillRecord(id: 'a', name: 'Inbox sweep'),
        ]),
      );
      await tester.pump();
      expect(find.text('Inbox sweep'), findsOneWidget);

      source.emit(
        const SkillListAvailable(<SkillRecord>[
          SkillRecord(id: 'b', name: 'Receipt capture'),
        ]),
      );
      await tester.pump();

      expect(find.text('Inbox sweep'), findsNothing);
      expect(find.text('Receipt capture'), findsOneWidget);
    });

    testWidgets('a 360dp screen lists records without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final source = FakeStateSource<SkillListState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SkillManagerScreen(source: source.stream, now: () => now),
        ),
      );
      source.emit(
        const SkillListAvailable(<SkillRecord>[
          SkillRecord(
            id: 'a',
            name: 'A skill with a deliberately very long display name',
            state: SkillState.needsReview,
            detail: 'And a deliberately long review detail as well.',
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('needs review'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
