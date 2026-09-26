// test/ui/live_task_view_test.dart — the Live Task View draws the timeline it
// is handed, with the timestamp the event really carries.
//
// The old view numbered its rows with a fabricated clock ("12:34", "12:35", …)
// derived from the row index, which made a static list look like a running
// task. An event with no timestamp now says so.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/ui/live_task_view.dart';

import 'fake_state_source.dart';

void main() {
  group('LiveTaskView', () {
    testWidgets('is unavailable — not invented — when no source is wired', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: LiveTaskView()));

      expect(
        find.text('No task timeline source is connected.'),
        findsOneWidget,
      );
      expect(find.textContaining('12:34'), findsNothing);
    });

    testWidgets('loading resolves into the events the source reported', (
      tester,
    ) async {
      final source = FakeStateSource<TaskTimelineState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: LiveTaskView(source: source.stream)),
      );
      await tester.pump();

      expect(find.text('Reading the task timeline…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      source.emit(
        TaskTimelineAvailable(<TaskTimelineEvent>[
          TaskTimelineEvent(
            id: 'e1',
            stage: 'planning',
            detail: 'Read the calendar dump.',
            phase: TaskPhase.completed,
            occurredAt: DateTime(2026, 1, 2, 3, 4, 5),
          ),
          TaskTimelineEvent(
            id: 'e2',
            stage: 'executing',
            detail: 'Gesture dispatch is gated by PolicyEngine.',
            phase: TaskPhase.recovering,
            occurredAt: null,
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('Reading the task timeline…'), findsNothing);
      expect(find.text('planning'), findsOneWidget);
      expect(find.text('Read the calendar dump.'), findsOneWidget);
      expect(find.text('completed'), findsOneWidget);
      expect(find.text('03:04:05'), findsOneWidget);
      expect(find.text('recovering'), findsOneWidget);
      // No timestamp was reported, so none is invented from the row order.
      expect(find.text('time unknown'), findsOneWidget);
      expect(find.textContaining('12:34'), findsNothing);
    });

    testWidgets('an empty timeline is empty, not a numbered list', (
      tester,
    ) async {
      final source = FakeStateSource<TaskTimelineState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: LiveTaskView(source: source.stream)),
      );
      source.emit(const TaskTimelineAvailable(<TaskTimelineEvent>[]));
      await tester.pump();

      expect(find.text('No task has been started yet.'), findsOneWidget);
      expect(find.textContaining(':'), findsNothing);
    });

    testWidgets('a failure shows the reason and retries only on demand', (
      tester,
    ) async {
      final source = FakeStateSource<TaskTimelineState>();
      addTearDown(source.close);
      var retries = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: LiveTaskView(source: source.stream, onRetry: () => retries++),
        ),
      );
      source.emit(const TaskTimelineFailed('Task runtime is not attached.'));
      await tester.pump();

      expect(find.text('Task runtime is not attached.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(retries, 0);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(retries, 1);
    });

    testWidgets('no retry control is drawn when nothing can be retried', (
      tester,
    ) async {
      final source = FakeStateSource<TaskTimelineState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: LiveTaskView(source: source.stream)),
      );
      source.emit(const TaskTimelineFailed('Task runtime is not attached.'));
      await tester.pump();

      expect(find.text('Task runtime is not attached.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a throwing source degrades to a failure state', (
      tester,
    ) async {
      final source = FakeStateSource<TaskTimelineState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: LiveTaskView(source: source.stream)),
      );
      source.fail(StateError('timeline socket closed'));
      await tester.pump();

      expect(find.textContaining('timeline socket closed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a later emission replaces the events already listed', (
      tester,
    ) async {
      final source = FakeStateSource<TaskTimelineState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: LiveTaskView(source: source.stream)),
      );
      source.emit(
        const TaskTimelineAvailable(<TaskTimelineEvent>[
          TaskTimelineEvent(id: 'e1', stage: 'planning', detail: 'First.'),
        ]),
      );
      await tester.pump();
      expect(find.text('First.'), findsOneWidget);

      source.emit(
        const TaskTimelineAvailable(<TaskTimelineEvent>[
          TaskTimelineEvent(id: 'e2', stage: 'executing', detail: 'Second.'),
          TaskTimelineEvent(id: 'e3', stage: 'verifying', detail: 'Third.'),
        ]),
      );
      await tester.pump();

      expect(find.text('First.'), findsNothing);
      expect(find.text('Second.'), findsOneWidget);
      expect(find.text('Third.'), findsOneWidget);
    });

    testWidgets('a 360dp screen lists events without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final source = FakeStateSource<TaskTimelineState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: LiveTaskView(source: source.stream)),
      );
      source.emit(
        TaskTimelineAvailable(<TaskTimelineEvent>[
          TaskTimelineEvent(
            id: 'e1',
            stage: 'executing',
            detail:
                'A deliberately long timeline detail that has to wrap '
                'inside a narrow phone viewport without overflowing.',
            phase: TaskPhase.recovering,
            occurredAt: DateTime(2026, 1, 2, 3, 4, 5),
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('recovering'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
