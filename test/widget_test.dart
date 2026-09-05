import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/main.dart';

void main() {
  testWidgets('NoirApp boots and renders the Command Centre screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(const NoirApp());
    expect(find.text('Ask Noir anything...'), findsOneWidget);
  });
}
