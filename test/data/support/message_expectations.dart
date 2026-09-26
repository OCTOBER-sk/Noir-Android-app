// Comparing messages field by field.
//
// lib/core/conversation_models.dart deliberately has no value equality, and the
// data layer must not change the model API just to make its own tests shorter.
// Losslessness is therefore asserted field by field here, which also makes a
// regression name the field that drifted.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/conversation_models.dart';

void expectMessagesMatch(
  List<ConversationMessage> actual,
  List<ConversationMessage> expected, {
  String reason = '',
}) {
  final why = reason.isEmpty ? '' : ' ($reason)';
  expect(actual.length, expected.length, reason: 'message count differs$why');
  for (var i = 0; i < expected.length; i++) {
    final a = actual[i];
    final e = expected[i];
    expect(a.id, e.id, reason: 'message $i id$why');
    expect(a.role, e.role, reason: 'message $i role$why');
    expect(a.text, e.text, reason: 'message $i text$why');
    expect(a.isStreaming, e.isStreaming, reason: 'message $i isStreaming$why');
    expect(a.content, e.content, reason: 'message $i content$why');
  }
}
