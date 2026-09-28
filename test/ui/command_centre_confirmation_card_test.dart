// test/ui/command_centre_confirmation_card_test.dart — the Command Centre's
// confirmation card is a real consent control, not a picture of one.
//
// THE DEFECT THIS PINS DOWN. `CommandCentreScreen` renders
// `_ConfirmationCard` for every `ConfirmationRequired` on the timeline, and that
// card drew its two controls through `_CardActionButton`, which hardcoded
// `enabled: false` and rendered a plain `Container` with no `onTap` anywhere in
// the tree. Underneath it printed the literal string
//
//   'Disabled: no policy gate is wired to this card yet.'
//
// That sentence was false. The gate is wired and is live in production:
//
//   lib/main.dart            OperationsSheet gets `confirmations: composition.confirmations`
//                            and an `onAnswerConfirmation` that calls `confirmation.answer`
//   composition_root.dart    `confirmations => gate.requests`; `runAutomation` mirrors every
//                            gate request into a `ConfirmationRequired` via `announceConfirmation`
//   operations_sheet.dart    `_ConfirmationPrompt` holds the outstanding request and renders
//                            working Approve / Deny
//
// so the request the Command Centre prints as a dead card was being answered on a
// different screen the user had to go and find. `FRONTEND_PLAN.md:20` requires
// working Confirm + Cancel on this card, and the card is the timeline's record of
// the same request, so the timeline is where the answer belongs.
//
// WHY IT IS DRIVEN THROUGH THE INJECTED WIRES. The events and the pending request
// are pushed through `events` / `confirmations`, which are the same parameters
// `main.dart` feeds from `composition.taskRun.events` and
// `composition.confirmations`. The answer is asserted twice on purpose: once as a
// spy on the injected callback, and once as `confirmation.answerValue` on the real
// `PendingConfirmation`. A callback spy alone would pass against a handler that
// took the argument and threw it away, which is precisely the kind of card this
// file is about.
//
// `PendingConfirmation.answer` is first-answer-wins and returns false once
// something has answered, so two screens may hold the same request without one
// cancelling the other's. That is why the enabled state is derived from
// `isAnswered` / `canBeApproved` here rather than trusted to the gate.
import 'package:flutter/material.dart';
// `SemanticsProperties` is what `Semantics` keeps its arguments in, and it is
// not re-exported by material.dart.
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/agent_wiring.dart';
import 'package:noir_android_app/core/conversation_controller.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';

import 'fake_state_source.dart';

void main() {
  const Key confirm = Key('confirmation-card-confirm');
  const Key cancel = Key('confirmation-card-cancel');

  /// The card's own copy, so a wording change is a deliberate edit here rather
  /// than a silent one that leaves the test green for the wrong reason.
  const String staleClaim = 'Disabled: no policy gate is wired to this card yet.';

  /// What `runAutomation` really publishes for one gated run: the same shape
  /// `taskRun.announceConfirmation` builds, so the card sees production fields.
  final ConfirmationRequired gatedRun = ConfirmationRequired(
    'Send the message on screen',
    1,
    'accessibility.send',
    true,
  );

  /// One real request from the real `ConsentGate`, built by hand the way the
  /// gate builds one so nothing here is a stand-in for the consent type itself.
  PendingConfirmation request({bool needsBiometric = false}) =>
      PendingConfirmation(
        requestId: 'req-1',
        action: 'send',
        riskLevel: needsBiometric ? 2 : 1,
        message: 'Send the message on screen?',
        needsBiometric: needsBiometric,
      );

  /// Everything the card is asserted through, plus the two sources a test pushes
  /// into. The default handler is the one `main.dart` installs: it forwards to
  /// `PendingConfirmation.answer`, which is the only call that can approve.
  Future<
    ({
      FakeStateSource<NoirUiEvent> events,
      FakeStateSource<PendingConfirmation> confirmations,
      List<(PendingConfirmation, bool)> answered,
    })
  >
  pumpScreen(
    WidgetTester tester, {
    bool withHandler = true,
  }) async {
    final controller = ConversationController();
    addTearDown(controller.close);
    final events = FakeStateSource<NoirUiEvent>();
    addTearDown(events.close);
    final confirmations = FakeStateSource<PendingConfirmation>();
    addTearDown(confirmations.close);
    final answered = <(PendingConfirmation, bool)>[];

    await tester.pumpWidget(
      MaterialApp(
        home: CommandCentreScreen(
          controller: controller,
          events: events.stream,
          confirmations: confirmations.stream,
          onAnswerConfirmation: withHandler
              ? (PendingConfirmation c, bool approved) {
                  answered.add((c, approved));
                  c.answer(approved);
                }
              : null,
        ),
      ),
    );
    return (
      events: events,
      confirmations: confirmations,
      answered: answered,
    );
  }

  /// Stream delivery is asynchronous, so each push needs its own pump.
  ///
  /// Defaults to the gated run so the tests that only care about the card do not
  /// have to restate the event.
  Future<void> deliver(
    WidgetTester tester,
    FakeStateSource<NoirUiEvent> events, [
    NoirUiEvent? event,
  ]) async {
    events.emit(event ?? gatedRun);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> deliverConfirmation(
    WidgetTester tester,
    FakeStateSource<PendingConfirmation> confirmations,
    PendingConfirmation confirmation,
  ) async {
    confirmations.emit(confirmation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// The accessibility state a button advertises. This is the signal a screen
  /// reader is given, so it is asserted directly rather than inferred from a
  /// colour that only looks right.
  ///
  /// Read off the `Semantics` widget rather than the built semantics tree:
  /// `WidgetTester.getSemantics` would need a `SemanticsHandle` that a failing
  /// test could not reach to dispose, and the extra failure would bury the
  /// assertion that actually matters.
  bool enabled(WidgetTester tester, Key key) {
    final SemanticsProperties properties =
        tester.widget<Semantics>(find.byKey(key)).properties;
    expect(properties.button, isTrue, reason: '$key must be announced as a button');
    return properties.enabled ?? false;
  }

  group('CommandCentreScreen confirmation card — request details', () {
    // These two are controls. They describe the card the fix must not change, so
    // they are expected to pass both before and after it.
    testWidgets('renders the gated run the event really described', (
      tester,
    ) async {
      final harness = await pumpScreen(tester);

      await deliver(tester, harness.events);

      expect(find.text(gatedRun.actionDescription), findsOneWidget);
      expect(find.text('Tool: accessibility.send'), findsOneWidget);
      expect(find.text('Sanitized: Yes'), findsOneWidget);
    });

    testWidgets('both controls are disabled with nothing connected', (
      tester,
    ) async {
      final harness = await pumpScreen(tester, withHandler: false);

      await deliver(tester, harness.events);

      expect(find.byKey(confirm), findsOneWidget);
      expect(find.byKey(cancel), findsOneWidget);
      expect(enabled(tester, confirm), isFalse);
      expect(enabled(tester, cancel), isFalse);
    });
  });

  group('CommandCentreScreen confirmation card — real consent', () {
    testWidgets('an outstanding request enables both controls', (tester) async {
      final harness = await pumpScreen(tester);
      final PendingConfirmation pending = request();

      await deliver(tester, harness.events);
      await deliverConfirmation(tester, harness.confirmations, pending);

      // The user is looking at this card when the gate starts waiting. Both
      // answers must be reachable here, not on a screen they have to find.
      expect(enabled(tester, confirm), isTrue);
      expect(enabled(tester, cancel), isTrue);
    });

    testWidgets('Confirm answers the held request with true', (tester) async {
      final harness = await pumpScreen(tester);
      final PendingConfirmation pending = request();
      await deliver(tester, harness.events);
      await deliverConfirmation(tester, harness.confirmations, pending);

      await tester.tap(find.byKey(confirm));
      await tester.pump();

      expect(harness.answered, hasLength(1));
      // Identical, not merely equal: the card must answer the request it is
      // showing, never a request it invented or a stale one it still remembers.
      expect(identical(harness.answered.single.$1, pending), isTrue);
      expect(harness.answered.single.$2, isTrue);
    });

    testWidgets('Cancel answers the held request with false', (tester) async {
      final harness = await pumpScreen(tester);
      final PendingConfirmation pending = request();
      await deliver(tester, harness.events);
      await deliverConfirmation(tester, harness.confirmations, pending);

      await tester.tap(find.byKey(cancel));
      await tester.pump();

      expect(harness.answered, hasLength(1));
      expect(identical(harness.answered.single.$1, pending), isTrue);
      expect(harness.answered.single.$2, isFalse);
    });

    testWidgets('the answer reaches the real PendingConfirmation', (
      tester,
    ) async {
      final harness = await pumpScreen(tester);
      final PendingConfirmation pending = request();
      await deliver(tester, harness.events);
      await deliverConfirmation(tester, harness.confirmations, pending);

      // A spy on the callback would not catch a handler that swallowed the
      // request, which is the same failure the dead buttons had.
      expect(pending.answerValue, isNull, reason: 'unanswered until tapped');
      await tester.tap(find.byKey(confirm));
      await tester.pump();
      expect(pending.isAnswered, isTrue);
      expect(pending.answerValue, isTrue);
    });

    testWidgets('an already-answered request is not answerable', (tester) async {
      final harness = await pumpScreen(tester);
      final PendingConfirmation pending = request();
      // The gate gave up waiting: another holder, or the timeout, answered it.
      pending.answer(false);
      await deliver(tester, harness.events);
      await deliverConfirmation(tester, harness.confirmations, pending);

      expect(enabled(tester, confirm), isFalse);
      expect(enabled(tester, cancel), isFalse);
      await tester.tap(find.byKey(confirm));
      await tester.tap(find.byKey(cancel));
      await tester.pump();
      expect(
        harness.answered,
        isEmpty,
        reason: 'a request the gate has released must not be answerable here',
      );
    });

    testWidgets('a biometric-demanding request cannot be confirmed', (
      tester,
    ) async {
      final harness = await pumpScreen(tester);
      await deliver(tester, harness.events);
      await deliverConfirmation(
        tester,
        harness.confirmations,
        request(needsBiometric: true),
      );

      // This build has no biometric binding, so approving is impossible however
      // the button is drawn. Refusing is still a real answer and stays available.
      expect(enabled(tester, confirm), isFalse);
      expect(enabled(tester, cancel), isTrue);
    });

    testWidgets('the card stops claiming no policy gate is wired', (
      tester,
    ) async {
      final harness = await pumpScreen(tester, withHandler: false);

      await deliver(tester, harness.events);

      // The sentence was false and is gone. What replaces it has to be true, so
      // the card also has to say where a request is actually answered.
      expect(find.text(staleClaim), findsNothing);
      expect(
        find.textContaining('Operations'),
        findsOneWidget,
        reason: 'with nothing connected, the card must name the screen that '
            'does hold the request',
      );
    });

    testWidgets('answering here releases the request this card holds', (
      tester,
    ) async {
      final harness = await pumpScreen(tester);
      final PendingConfirmation pending = request();
      await deliver(tester, harness.events);
      await deliverConfirmation(tester, harness.confirmations, pending);

      await tester.tap(find.byKey(confirm));
      await tester.pump();

      // The gate has the answer, so this screen stops holding a request it
      // could re-answer and says so instead of pretending one is outstanding.
      expect(pending.answerValue, isTrue);
      expect(enabled(tester, confirm), isFalse);
      expect(enabled(tester, cancel), isFalse);
      expect(
        find.text('No confirmation request is outstanding for this card.'),
        findsOneWidget,
      );
    });

    testWidgets('a request answered by the other holder stops being answerable', (
      tester,
    ) async {
      final harness = await pumpScreen(tester);
      final PendingConfirmation pending = request();
      await deliver(tester, harness.events);
      await deliverConfirmation(tester, harness.confirmations, pending);
      expect(enabled(tester, confirm), isTrue);

      // The Operations sheet's holder answers the same request. Nothing
      // notifies this screen of that, so the card can only re-derive on its next
      // rebuild — which the same run produces, because a gated run always
      // reports something after the decision. Until then the card is stale, and
      // what holds the line is `answer` itself: a tap on a stale card cannot
      // approve anything, and both halves of that are asserted here.
      pending.answer(true);
      await deliver(
        tester,
        harness.events,
        ToolCallCompleted('accessibility.send', true),
      );

      expect(enabled(tester, confirm), isFalse);
      expect(enabled(tester, cancel), isFalse);
      expect(
        find.text('This request was answered: approved once.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(confirm));
      await tester.pump();
      expect(pending.answerValue, isTrue, reason: 'a stale card cannot re-answer');
      expect(
        find.text('This request was answered: refused or expired, so nothing runs.'),
        findsNothing,
        reason: 'a tap that changes nothing must not restate the request',
      );
    });
  });
}
