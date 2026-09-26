// lib/providers/mcp/mcp_safety.dart — per-tool safety classification.
//
// B2's rule, kept literally: classify per TOOL, never per server. A server that
// exposes one destructive tool is not thereby a destructive server, and a
// server that exposes one read-only tool is not thereby safe — the allowlist
// is per tool and so is the gate.
//
// Inputs, in precedence order:
//
//   1. the operator's own [MCPToolDef] on the allowlist (they know their tool);
//   2. the server's MCP `annotations` (readOnlyHint / destructiveHint /
//      openWorldHint) — but only when they do not contradict the tool's name;
//   3. the tool's name and description, matched word by word (deterministic verb
//      matching — a verb has to start a word, so `focus_input` is a screen tool
//      and not an HTTP PUT);
//   4. nothing usable, in which case the tool FAILS CLOSED at HIGH_RISK.
//
// An operator override may say "background safe" but it can never erase a
// destructive or open-world FACT: those keep the gate on, because a bad
// annotation from a hostile server must not become a permission.
import '../../safety/risk_classifier.dart' show RiskTier;
import 'mcp_protocol.dart';

/// Verbs that read state without changing it.
const List<String> kMcpReadVerbs = <String>[
  'read',
  'get',
  'list',
  'search',
  'find',
  'fetch',
  'query',
  'describe',
  'inspect',
  'scan',
  'grep',
  'count',
  'summar',
  'export',
  'stat',
  'lookup',
  'browse',
  'check',
  'show',
  'retrieve',
];

/// Verbs that need a screen (the accessibility service) to mean anything.
const List<String> kMcpUiVerbs = <String>[
  'tap',
  'click',
  'swipe',
  'scroll',
  'type',
  'input',
  'press',
  'focus',
  'navigate',
  'launch',
  'open',
  'drag',
  'longpress',
  'screenshot',
  'gesture',
];

/// Verbs that change state or reach the outside world.
const List<String> kMcpMutationVerbs = <String>[
  'delete',
  'remove',
  'write',
  'update',
  'create',
  'send',
  'post',
  'put',
  'patch',
  'exec',
  'execute',
  'run',
  'install',
  'commit',
  'push',
  'drop',
  'truncate',
  'rename',
  'move',
  'copy',
  'upload',
  'download',
  'purchase',
  'pay',
  'buy',
  'transfer',
  'email',
  'message',
  'share',
  'publish',
  'deploy',
  'replace',
  'clear',
  'purge',
  'wipe',
  'format',
  'restart',
  'reboot',
  'shell',
];

/// The verdict for one tool, plus the evidence that produced it.
class McpToolSafety {
  const McpToolSafety({
    required this.name,
    required this.backgroundSafe,
    required this.uiBound,
    required this.readOnly,
    required this.destructive,
    required this.openWorld,
    required this.requiresGate,
    required this.suggestedRiskLevel,
    required this.basis,
  });

  final String name;

  /// True only when the tool provably needs no UI interaction and no gate.
  final bool backgroundSafe;

  /// True when the tool drives or reads the screen (AccessibilityService).
  final bool uiBound;

  /// Reads state without changing it.
  final bool readOnly;

  /// Can destroy data.
  final bool destructive;

  /// Reaches entities outside this device (the open world).
  final bool openWorld;

  /// A PolicyEngine verdict (confirmation/biometric) is required first. Noir's
  /// PolicyEngine stays the only authority; this is the requirement, not the
  /// approval.
  final bool requiresGate;

  /// Risk level 0-3 in the A6 sense, for the gate call. Not an approval.
  final int suggestedRiskLevel;

  /// Where the verdict came from: `operator-override`, `annotations`,
  /// `annotations-conflict`, `name-heuristic` or `unknown-fail-closed`.
  final String basis;

  RiskTier get tier {
    if (suggestedRiskLevel <= 0) return RiskTier.SAFE;
    if (suggestedRiskLevel == 1) return RiskTier.STANDARD;
    if (suggestedRiskLevel == 2) return RiskTier.SENSITIVE;
    return RiskTier.HIGH_RISK;
  }

  /// Whether this tool may run with no user present and no gate. A single
  /// false fact is enough to say no.
  bool get allowsBackgroundExecution =>
      backgroundSafe && !requiresGate && !destructive && !openWorld && !uiBound;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tool': name,
    'backgroundSafe': backgroundSafe,
    'uiBound': uiBound,
    'readOnly': readOnly,
    'destructive': destructive,
    'openWorld': openWorld,
    'requiresGate': requiresGate,
    'suggestedRiskLevel': suggestedRiskLevel,
    'tier': tier.name,
    'basis': basis,
  };

  @override
  String toString() => 'McpToolSafety($name, ${toJson()})';
}

/// One tool on an operator's allowlist: name, description and the safety
/// declaration the operator made about it.
class MCPToolDef {
  /// An operator-authored declaration. [safety] is the classification implied
  /// by the declaration itself, so a def is never unclassified.
  MCPToolDef({
    required this.name,
    required this.description,
    this.backgroundSafe = false,
    this.uiBound = false,
  }) : safety = const McpToolClassifier().classifyTool(
         name: name,
         description: description,
         overrideBackgroundSafe: backgroundSafe,
         overrideUiBound: uiBound,
       );

  const MCPToolDef._classified({
    required this.name,
    required this.description,
    required this.backgroundSafe,
    required this.uiBound,
    required this.safety,
  });

  /// Builds a def from what the server actually advertised, with the
  /// operator's declaration layered on top when one exists.
  factory MCPToolDef.fromSpec(McpToolSpec spec, {MCPToolDef? override}) {
    final McpToolSafety verdict = const McpToolClassifier().classifyTool(
      name: spec.name,
      description: spec.description,
      annotations: spec.annotations,
      override: override,
    );
    return MCPToolDef._classified(
      name: spec.name,
      description: spec.description.isEmpty ? spec.name : spec.description,
      backgroundSafe: verdict.backgroundSafe,
      uiBound: verdict.uiBound,
      safety: verdict,
    );
  }

  final String name;
  final String description;
  final bool backgroundSafe;
  final bool uiBound;
  final McpToolSafety safety;

  Map<String, dynamic> toJson() => safety.toJson();
}

/// Deterministic classifier. No LLM, no guessing: verb lists plus the server's
/// own annotations, and a fail-closed default.
class McpToolClassifier {
  const McpToolClassifier();

  McpToolSafety classify(McpToolSpec spec, {MCPToolDef? override}) =>
      classifyTool(
        name: spec.name,
        description: spec.description,
        annotations: spec.annotations,
        override: override,
      );

  McpToolSafety classifyTool({
    required String name,
    String description = '',
    Map<String, dynamic>? annotations,
    MCPToolDef? override,
    bool? overrideBackgroundSafe,
    bool? overrideUiBound,
  }) {
    // A tool is named by its words, so the verbs are matched word by word.
    final List<String> words = _words('$name $description');
    final bool reads = _matchesAny(words, kMcpReadVerbs);
    final bool drives = _matchesAny(words, kMcpUiVerbs);
    final bool mutates = _matchesAny(words, kMcpMutationVerbs);

    final bool? readOnlyHint = _boolHint(annotations, 'readOnlyHint');
    final bool? destructiveHint = _boolHint(annotations, 'destructiveHint');
    final bool? openWorldHint = _boolHint(annotations, 'openWorldHint');
    final bool annotated =
        readOnlyHint != null ||
        destructiveHint != null ||
        openWorldHint != null;

    final bool operatorBackground =
        override?.backgroundSafe ?? overrideBackgroundSafe ?? false;
    final bool operatorUiBound = override?.uiBound ?? overrideUiBound ?? false;
    final bool hasOverride =
        override != null ||
        overrideBackgroundSafe != null ||
        overrideUiBound != null;

    bool readOnly = readOnlyHint ?? reads;
    bool destructive = destructiveHint ?? mutates;
    bool openWorld = openWorldHint ?? false;
    bool uiBound = drives;
    bool backgroundSafe;
    String basis;

    if (annotated) {
      final bool conflict = (readOnlyHint == true) && (mutates || drives);
      if (conflict) {
        // The server claims to be read-only but names a mutating or
        // screen-driving verb. The claim is the suspicious part, not the name.
        readOnly = false;
        backgroundSafe = false;
        basis = 'annotations-conflict';
      } else {
        backgroundSafe = readOnly && !destructive && !openWorld;
        basis = 'annotations';
      }
    } else if (reads || drives || mutates) {
      readOnly = reads && !mutates && !drives;
      backgroundSafe = readOnly;
      basis = 'name-heuristic';
    } else {
      readOnly = false;
      destructive = false;
      openWorld = false;
      uiBound = false;
      backgroundSafe = false;
      basis = 'unknown-fail-closed';
    }

    if (uiBound) {
      // A screen-bound tool is never background safe: it needs a live UI context.
      backgroundSafe = false;
    }

    var background = backgroundSafe;
    if (hasOverride) {
      // The operator's declaration wins for the permission, but only when it
      // disagrees with the computed verdict, and never over a destructive or
      // open-world fact.
      if (operatorBackground != background) {
        background = operatorBackground;
        basis = 'operator-override';
      }
      if (operatorUiBound) {
        uiBound = true;
        background = false;
        basis = 'operator-override';
      }
    }
    if (destructive || openWorld) background = false;

    final bool requiresGate = destructive || openWorld || !background;
    final int risk = destructive
        ? 3
        : openWorld
        ? 2
        : background
        ? 0
        : uiBound
        ? 1
        : 3;

    return McpToolSafety(
      name: name,
      backgroundSafe: background,
      uiBound: uiBound,
      readOnly: readOnly,
      destructive: destructive,
      openWorld: openWorld,
      requiresGate: requiresGate,
      suggestedRiskLevel: risk,
      basis: basis,
    );
  }

  static bool? _boolHint(Map<String, dynamic>? annotations, String key) {
    if (annotations == null) return null;
    final Object? value = annotations[key];
    return value is bool ? value : null;
  }

  /// Splits [text] into lowercase words on everything that is not a letter or a
  /// digit, so `read_note`, `readNote`, `read-note` and "read note" all yield the
  /// word `read`, and `focus_input` yields two words rather than one blob.
  static List<String> _words(String text) => text
      .toLowerCase()
      .split(RegExp('[^a-z0-9]+'))
      .where((String word) => word.isNotEmpty)
      .toList(growable: false);

  /// Whether any word in [words] *starts* with one of [verbs].
  ///
  /// Word-anchored on purpose. A bare substring match invents facts out of
  /// unrelated words: "computer" and "focus_input" both contain "put", the HTTP
  /// verb, so a screen-bound tool that moves no data would be classified
  /// destructive at HIGH_RISK, would need a biometric Noir cannot perform, and
  /// would never be callable at all. A prefix match still reads `read_note` and
  /// `readNote` as reads, and it is strictly narrower than the substring match it
  /// replaces, so it can only move a tool towards the `unknown-fail-closed`
  /// HIGH_RISK default, never away from it: a verb no longer recognised this way
  /// lands in the fail-closed branch above rather than being read as safe.
  static bool _matchesAny(List<String> words, List<String> verbs) {
    for (final String word in words) {
      for (final String verb in verbs) {
        if (word.startsWith(verb)) return true;
      }
    }
    return false;
  }
}
