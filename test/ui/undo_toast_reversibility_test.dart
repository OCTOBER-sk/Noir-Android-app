// test/ui/undo_toast_reversibility_test.dart — D15 undo toast states.
//
// `FRONTEND_PLAN.md:41` and the E5 gate list (`FRONTEND_PLAN.md:51`) require:
//   * the toast says `<actionDescription> just happened.`
//   * when `reversible` is false it shows "Irreversible action completed." and
//     NO Undo control
//   * when `reversible` is true an Undo control IS shown
//
// This is the only E5 gate in that list with no test anywhere in `test/`
// (the consumer-coverage gate is `test/ui_event_contract_test.dart`, the
// provenance gate is `command_centre_confirmation_card_test.dart`, the skeleton
// gate is `command_centre_skeleton_lifecycle_test.dart`). Without it, a change
// that renders an Undo button on an irreversible action — a control that can
// never fire — would stay green.
//
// The widget is driven directly because `UndoToast` is a pure function of one
// `ActionCompletedWithUndoWindow`; the production path that selects it for that
// event is `command_centre_screen.dart:1287`, already covered for delivery by
// the skeleton lifecycle test. What is under test here is the branch the widget
// takes, not the plumbing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';

void main() {
  const String irreversibleCopy = 'Irreversible action completed.';

  Widget host(ActionCompletedWithUndoWindow event) => MaterialApp(
    home: Scaffold(body: UndoToast(event: event)),
  );

  group('UndoToast — irreversible action', () {
    testWidgets('says the action happened and offers no Undo control', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ActionCompletedWithUndoWindow(
            'Deleted the note',
            false,
            const Duration(seconds: 5),
          ),
        ),
      );

      expect(find.text('Deleted the note just happened.'), findsOneWidget);
      expect(find.text(irreversibleCopy), findsOneWidget);
      // No Undo affordance at all — the label text itself is gone.
      expect(find.text('Undo'), findsNothing);
    });
  });

  group('UndoToast — reversible action', () {
    testWidgets('says the action happened and shows the Undo control', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ActionCompletedWithUndoWindow(
            'Moved the note to Archive',
            true,
            const Duration(seconds: 5),
          ),
        ),
      );

      expect(
        find.text('Moved the note to Archive just happened.'),
        findsOneWidget,
      );
      expect(find.text(irreversibleCopy), findsNothing);
      expect(find.text('Undo'), findsOneWidget);
    });
  });
}
