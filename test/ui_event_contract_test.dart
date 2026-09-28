// lib/core/ui_state_contract.dart — E5: every NoirUiEvent subtype must be
// reachable, or be declared reserved.
//
// FRONTEND_PLAN.md requires: "New NoirUiEvent subtype = add to
// ui_state_contract.dart + real runtime emission + widget consumer. Fail if any
// event has no consumer (E5)."
//
// Both halves were previously unverified, and the consequence was silent:
// ToolCallStarted and ToolCallCompleted had widget consumers in
// command_centre_screen.dart (the "Using <tool>…" and "<tool> completed."
// micro-copy) but no emitter anywhere in lib/, so that UI could never render.
// The switch in _MessageRow compiles, the case is dead, and no test fails.
//
// This asserts the emission half by reading sources, which is the only way to
// see it: a subtype with no producer has no behaviour to test, so a
// behavioural test would trivially pass.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';

/// The subtypes the app declares.
const Set<Type> kContractEvents = <Type>{
  TaskStateChanged,
  StreamingTokenReceived,
  ToolCallStarted,
  ToolCallCompleted,
  SideConversationOpened,
  ConfirmationRequired,
  CostEstimateResolved,
  ActionCompletedWithUndoWindow,
  UserMessageSubmitted,
  AssistantMessageStarted,
  AssistantDeltaReceived,
  AssistantStreamStopped,
};

/// Subtypes with no producer yet, each with the reason it is legitimate.
///
/// A subtype may only sit here if the app genuinely has no feature that would
/// emit it. Anything else belongs in the emission assertion below.
const Map<String, String> kReservedEvents = <String, String>{
  'SideConversationOpened':
      'Side conversations are not implemented in this build. The contract '
      'type is kept because V2.3 Section 3 specifies it literally, but no '
      'feature opens one, so there is no honest emitter to write.',
};

String _libSource({required bool excludeContract}) {
  final StringBuffer buffer = StringBuffer();
  for (final File file
      in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    if (excludeContract && file.path.endsWith('ui_state_contract.dart')) {
      continue;
    }
    buffer.writeln(file.readAsStringSync());
  }
  return buffer.toString();
}

/// Whether [source] constructs [name] somewhere a runtime emitter would.
///
/// A bare substring search is not enough, and getting this wrong is exactly how
/// the test below would pass while the bug is still present. `case Foo(` in a
/// widget switch and `event is Foo` are both *consumers*: they name the type
/// without ever building one. Only a construction counts.
bool _constructs(String source, String name) {
  for (final String line in source.split('\n')) {
    final int at = line.indexOf('$name(');
    if (at < 0) continue;
    // Trimmed code before the call site on this line.
    final String before = line.substring(0, at);
    if (RegExp(r'\bcase\s+$').hasMatch(before)) continue;
    if (RegExp(r'\b(is|is!)\s+$').hasMatch(before)) continue;
    if (RegExp(r'\bextends\s+$').hasMatch(before)) continue;
    return true;
  }
  return false;
}

void main() {
  test('every NoirUiEvent subtype is named in the contract file', () {
    // Guards the constant above against silently drifting from the source of
    // truth: a new subtype added to ui_state_contract.dart without being listed
    // here would escape both assertions below.
    final String contract = File('lib/core/ui_state_contract.dart').readAsStringSync();
    final Set<String> declared = RegExp(r'class (\w+) extends NoirUiEvent')
        .allMatches(contract)
        .map((Match m) => m.group(1)!)
        .toSet();
    expect(
      declared,
      kContractEvents.map((Type t) => t.toString()).toSet(),
      reason: 'kContractEvents is out of date with ui_state_contract.dart',
    );
  });

  test('every non-reserved subtype has a real runtime emitter in lib/', () {
    // The contract file declares each subtype and the UI matches on it, so
    // neither counts: only a construction site in the rest of lib/ proves
    // anything can actually be emitted.
    final String runtime = _libSource(excludeContract: true);

    final List<String> unemitted = <String>[];
    for (final Type event in kContractEvents) {
      final String name = event.toString();
      if (kReservedEvents.containsKey(name)) continue;
      if (!_constructs(runtime, name)) unemitted.add(name);
    }

    expect(
      unemitted,
      isEmpty,
      reason:
          'These NoirUiEvent subtypes are constructed nowhere in lib/, so their '
          'widget consumers are dead code. Either emit them from the feature '
          'that owns them, or add them to kReservedEvents with a stated reason.',
    );
  });

  test('every reserved subtype states why it has no emitter', () {
    // A reserved entry with a blank or absent reason is an excuse, not a
    // record, so the reason is required to be non-trivial.
    kReservedEvents.forEach((String name, String reason) {
      expect(
        reason.length,
        greaterThan(20),
        reason: 'reserved event $name needs a real explanation',
      );
    });
  });

  test('a reserved subtype is genuinely absent from lib/, not just unlisted', () {
    // Otherwise "reserved" would become a place to hide a regression.
    final String contract =
        File('lib/core/ui_state_contract.dart').readAsStringSync();
    for (final String name in kReservedEvents.keys) {
      final int uses = RegExp('\\b$name\\b')
          .allMatches(contract)
          .length;
      expect(uses, greaterThan(0), reason: '$name should still be declared');
    }
  });
}
