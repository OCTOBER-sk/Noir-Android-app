// test/undo_executor_test.dart — A6b: the undo window carries an action that
// can really be undone, and says so honestly.
//
// THREE DEFECTS THIS PINS DOWN, all of them in the same five seconds of one
// automated action:
//
//  1. THE WINDOW WAS ANNOUNCED AT THE WRONG MOMENT. `CountdownUndoWindow.open`
//     published its `ActionCompletedWithUndoWindow` from `finish()`, so the
//     toast only appeared once the window was already over. A control that
//     appears after the countdown it belongs to has ended can never be pressed
//     in time, which is why the D15 button had nothing to fire.
//  2. `reversible` WAS THE ENDING, NOT THE CAPABILITY. It was published as
//     `outcome == UndoOutcome.cancelled`: an action was announced as
//     reversible only *after* the user had already reversed it, and an action
//     nobody pressed was announced as irreversible. Reversibility is a property
//     of the action, so it is read off the action here.
//  3. THE WINDOW HELD NOTHING TO UNDO. It carried an `actionId` and a
//     `cancelled` flag, so there was no plan, no executor and no inverse. The
//     toast's button had no path to the gesture that ran, and the honest answer
//     was the string "undo is not wired to an action executor yet".
//
// The action under test is built from the real pieces: a `Plan` carrying a real
// proposal, the real `NativeGestureOutcome` the platform would have returned,
// and the compensation the app can actually dispatch for that verb. The
// executor is a counter and nothing more, because what is asserted here is which
// records exist and what the window claims about them — the dispatch itself is
// asserted in test/composition_root_test.dart, against the real bridge.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/core/agent_wiring.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';
import 'package:noir_android_app/platform/native_bridge.dart';

/// The verdict a dispatch carries when the platform confirmed it.
const NativeGateVerdict _allowed = NativeGateVerdict(
  allowed: true,
  message: 'ok',
);

/// The executor the real graph would have dispatched through, reduced to a
/// counter: nothing here asserts on the dispatch, only on what the window
/// publishes and what it hands to whoever presses Undo.
class _CountingExecutor implements Executor {
  int calls = 0;

  @override
  Future<dynamic> run(Plan plan) async {
    calls++;
    return NativeGestureOutcome(executed: true, verdict: _allowed);
  }
}

/// One action, exactly as the pipeline assembles it after a real run: the plan
/// that ran, the risk it was classified at, the executor that ran it, the
/// platform's own answer, and the compensation for its verb (null when the verb
/// has no inverse this build can dispatch).
UndoableAction _action({
  String verb = 'navigate',
  String input = 'maps',
  required _CountingExecutor executor,
  bool executed = true,
}) {
  final Plan plan = Plan(
    content: <String, dynamic>{'action': verb, 'input': input},
  );
  return UndoableAction(
    plan: plan,
    riskLevel: 1,
    executor: executor,
    outcome: NativeGestureOutcome(executed: executed, verdict: _allowed),
    compensation: compensationFor(plan.content),
  );
}

void main() {
  group('the window is announced while it is still open', () {
    test('the toast is published at open, before anything is over', () async {
      final List<ActionCompletedWithUndoWindow> published =
          <ActionCompletedWithUndoWindow>[];
      final CountdownUndoWindow undo = CountdownUndoWindow(
        publish: published.add,
      );
      addTearDown(undo.dispose);

      final _CountingExecutor executor = _CountingExecutor();
      final UndoableAction action = _action(executor: executor);
      final Future<UndoState> opened = undo.open(30, action: action);

      expect(
        published,
        hasLength(1),
        reason:
            'the countdown has not ended, so the announcement of the countdown '
            'cannot still be waiting for it to end',
      );
      expect(published.single.actionId, isNotEmpty);
      expect(undo.live, isNotNull);
      expect(undo.live!.actionId, published.single.actionId);

      undo.cancel();
      await opened;
      expect(
        published,
        hasLength(1),
        reason: 'ending a window must not re-announce it',
      );
    });
  });

  group('reversible follows compensatability, not the ending', () {
    // Every ending, both kinds of action, one assertion each: the flag says
    // what can be undone, so the same action reports the same thing whether
    // the user pressed Undo or the clock ran out. It used to be
    // `outcome == UndoOutcome.cancelled`, which reported "reversible" only once
    // the user had already reversed the action and "irreversible" whenever
    // nobody pressed anything.
    for (final _Ending ending in _Ending.values) {
      test(
        'a navigable action is reversible when the window ${ending.name}',
        () async {
          final List<ActionCompletedWithUndoWindow> published =
              <ActionCompletedWithUndoWindow>[];
          final CountdownUndoWindow undo = CountdownUndoWindow(
            publish: published.add,
          );
          addTearDown(undo.dispose);
          final Future<UndoOutcome> outcome = undo.outcomes.first;

          final UndoableAction action = _action(executor: _CountingExecutor());
          expect(
            action.isCompensatable,
            isTrue,
            reason: 'a navigation has an inverse this build can dispatch',
          );
          final Future<UndoState> opened = undo.open(
            1,
            action: action,
            allowed: ending.opens,
          );
          if (ending == _Ending.cancelled) undo.cancel();

          expect(published, hasLength(ending.opens ? 1 : 0));
          if (ending.opens) expect(published.single.reversible, isTrue);
          expect(await outcome, ending.expected);
          await opened;
        },
      );

      test('an action with no inverse is irreversible when the window '
          '${ending.name}', () async {
        final List<ActionCompletedWithUndoWindow> published =
            <ActionCompletedWithUndoWindow>[];
        final CountdownUndoWindow undo = CountdownUndoWindow(
          publish: published.add,
        );
        addTearDown(undo.dispose);
        final Future<UndoOutcome> outcome = undo.outcomes.first;

        // A tap cannot be untapped, so this build names no inverse for it.
        final UndoableAction action = _action(
          verb: 'tap',
          executor: _CountingExecutor(),
        );
        expect(action.isCompensatable, isFalse);
        final Future<UndoState> opened = undo.open(
          1,
          action: action,
          allowed: ending.opens,
        );
        if (ending == _Ending.cancelled) undo.cancel();

        expect(published, hasLength(ending.opens ? 1 : 0));
        if (ending.opens) expect(published.single.reversible, isFalse);
        expect(await outcome, ending.expected);
        await opened;
      });
    }

    test('a caller that may not open a window announces nothing', () async {
      final List<ActionCompletedWithUndoWindow> published =
          <ActionCompletedWithUndoWindow>[];
      final CountdownUndoWindow undo = CountdownUndoWindow(
        publish: published.add,
      );
      addTearDown(undo.dispose);
      final Future<UndoOutcome> outcome = undo.outcomes.first;

      await undo.open(
        5,
        action: _action(executor: _CountingExecutor()),
        allowed: false,
      );

      expect(await outcome, UndoOutcome.notAllowed);
      expect(
        published,
        isEmpty,
        reason:
            'a window that was never opened has no countdown to announce, and '
            'an announcement here would be a control with no time left on it',
      );
    });
  });

  group('an action the executor did not confirm is not offered an undo', () {
    test('no window, no announcement, and the reason is notExecuted', () async {
      final List<ActionCompletedWithUndoWindow> published =
          <ActionCompletedWithUndoWindow>[];
      final CountdownUndoWindow undo = CountdownUndoWindow(
        publish: published.add,
      );
      addTearDown(undo.dispose);
      final Future<UndoOutcome> outcome = undo.outcomes.first;

      // The platform answered without `executed`, so nothing happened on the
      // screen. "action just happened" would be a claim nothing backs.
      final UndoableAction action = _action(
        executor: _CountingExecutor(),
        executed: false,
      );
      expect(action.completed, isFalse);

      await undo.open(30, action: action);

      expect(await outcome, UndoOutcome.notExecuted);
      expect(published, isEmpty);
      expect(undo.live, isNull);
    });
  });

  group('the live window carries the action until it ends', () {
    test(
      'cancelling releases the action, so a second press finds nothing',
      () async {
        final CountdownUndoWindow undo = CountdownUndoWindow();
        addTearDown(undo.dispose);

        final UndoableAction action = _action(executor: _CountingExecutor());
        final Future<UndoState> opened = undo.open(30, action: action);

        final LiveUndoWindow? live = undo.live;
        expect(live, isNotNull);
        expect(live!.action.isCompensatable, isTrue);
        expect(live.action.plan.content, action.plan.content);
        expect(identical(live.action.executor, action.executor), isTrue);

        undo.cancel();
        await opened;

        expect(
          undo.live,
          isNull,
          reason: 'a spent window holds nothing to undo',
        );
      },
    );

    test('a window nobody cancelled still releases the action', () async {
      final CountdownUndoWindow undo = CountdownUndoWindow();
      addTearDown(undo.dispose);

      final Future<UndoState> opened = undo.open(
        1,
        action: _action(executor: _CountingExecutor()),
      );
      expect(undo.live, isNotNull);

      await opened;
      expect(undo.live, isNull);
    });
  });

  group('compensatability is a capability, not a guess', () {
    test('navigation is compensatable and the inverse names no screen', () {
      final Compensation? compensation = compensationFor(
        const <String, dynamic>{'action': 'navigate', 'input': 'maps'},
      );

      expect(compensation, isNotNull);
      expect(compensation!.action, isNotEmpty);
      expect(compensation.input, isNotEmpty);
    });

    test('an action this build cannot reverse names no inverse', () {
      for (final String verb in <String>[
        'tap',
        'send',
        'delete',
        'read_screen',
        'search',
        'save_fact',
        '',
      ]) {
        expect(
          compensationFor(<String, dynamic>{'action': verb}),
          isNull,
          reason: '"$verb" has no inverse this build can dispatch',
        );
      }
    });

    test('a proposal that is not a proposal is not compensatable', () {
      expect(compensationFor(null), isNull);
      expect(compensationFor('navigate'), isNull);
      expect(compensationFor(const <Object>['navigate']), isNull);
    });

    test('an action describes itself from the proposal that ran', () {
      expect(
        _action(executor: _CountingExecutor()).description,
        'navigate "maps"',
      );
      expect(
        _action(
          verb: 'tap',
          input: '',
          executor: _CountingExecutor(),
        ).description,
        'tap',
      );
    });
  });
}

/// The three ways an undo window can end, so the reversibility assertion can be
/// made for all of them instead of for whichever one the test happened to pick.
enum _Ending {
  cancelled(UndoOutcome.cancelled),
  elapsed(UndoOutcome.elapsed),
  notAllowed(UndoOutcome.notAllowed);

  const _Ending(this.expected);

  final UndoOutcome expected;

  /// Whether a window was opened at all. `notAllowed` never is, so it has
  /// nothing to announce and nothing to press.
  bool get opens => this != _Ending.notAllowed;
}
