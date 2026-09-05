import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';
import 'package:noir_android_app/ui/message_bubble.dart';

void main() {
  testWidgets('CommandCentre shows input, accepts text, renders message',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: CommandCentreScreen(),
    ));

    // Input field is present.
    final field = find.byType(TextField);
    expect(field, findsOneWidget);

    // Type into the field.
    await tester.enterText(field, 'hello noir');
    expect(find.text('hello noir'), findsOneWidget);

    // Send the message.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();

    // The sent text now appears as a user message bubble.
    expect(find.text('hello noir'), findsWidgets);
    expect(find.byType(MessageBubble), findsOneWidget);
  });
}
