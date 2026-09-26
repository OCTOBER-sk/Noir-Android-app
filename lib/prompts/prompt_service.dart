// lib/prompts/prompt_service.dart
// Named prompt templates with versions, enable/disable, explicit composition
// and secret redaction.
//
// Two rules shape this file:
//   1. Template content is never applied implicitly. There is no default
//      template and no ambient merge: text exists only if the caller names a
//      template through `compose`, and only the templates that name exists are
//      rendered.
//   2. Secrets do not leave the building. Composed text is redacted, and the
//      kinds found are reported on the template and on the composition.
import '../core/clock.dart';

/// Raised for every rejected input or unknown name.
class PromptValidationException implements Exception {
  const PromptValidationException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() =>
      'PromptValidationException($code${detail == null ? '' : ': $detail'})';
}

/// One immutable revision of a template body.
class PromptTemplateVersion {
  const PromptTemplateVersion({
    required this.version,
    required this.body,
    required this.createdAt,
    this.note,
  });

  final int version;
  final String body;
  final DateTime createdAt;

  /// Optional note recorded by the caller when the revision was written.
  final String? note;
}

/// A named template. [history] holds every revision including the current one,
/// oldest first.
class PromptTemplate {
  const PromptTemplate({
    required this.name,
    required this.body,
    required this.version,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    required this.history,
    this.includes = const <String>[],
    this.redactions = const <String>[],
  });

  final String name;
  final String body;
  final int version;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<PromptTemplateVersion> history;

  /// Names of the templates this one pulls in, in composition order.
  final List<String> includes;

  /// Secret kinds detected in [body] or in any included body.
  final List<String> redactions;

  PromptTemplate copyWith({
    String? body,
    int? version,
    bool? enabled,
    DateTime? updatedAt,
    List<PromptTemplateVersion>? history,
    List<String>? includes,
    List<String>? redactions,
  }) {
    return PromptTemplate(
      name: name,
      body: body ?? this.body,
      version: version ?? this.version,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      history: history ?? this.history,
      includes: includes ?? this.includes,
      redactions: redactions ?? this.redactions,
    );
  }

  @override
  String toString() => 'PromptTemplate($name, v$version, enabled: $enabled)';
}

/// One rendered template inside a composition.
class PromptSection {
  const PromptSection({
    required this.name,
    required this.version,
    required this.text,
  });

  final String name;
  final int version;

  /// The rendered, redacted text of this section, without its header.
  final String text;
}

/// The result of an explicit `compose` call.
class PromptComposition {
  const PromptComposition({
    required this.root,
    required this.version,
    required this.order,
    required this.sections,
    required this.text,
    required this.redactions,
  });

  /// The template the caller asked for.
  final String root;

  final int version;

  /// Template names in the exact order they were rendered.
  final List<String> order;

  final List<PromptSection> sections;

  /// The composed text, redacted.
  final String text;

  /// Secret kinds removed while composing, in detection order.
  final List<String> redactions;
}

class PromptService {
  PromptService({Clock? clock, this.maxBodyLength = 5000})
    : clock = clock ?? const SystemClock();

  final Clock clock;

  /// Upper bound on a single template body.
  final int maxBodyLength;

  final Map<String, PromptTemplate> _templates = <String, PromptTemplate>{};

  /// `a-z 0-9 . _ -`, starting alphanumeric, at most 64 characters. A name is
  /// an identifier, not a sentence, so it can be passed around safely.
  static final RegExp _namePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

  static final RegExp _placeholder = RegExp(r'\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}');

  /// Names in ascending order.
  List<String> names() => _templates.keys.toList()..sort();

  /// Templates ordered by name.
  List<PromptTemplate> templates() =>
      names().map((String name) => _templates[name]!).toList();

  PromptTemplate? get(String name) => _templates[name.trim()];

  /// Every recorded revision, oldest first, current body last.
  List<PromptTemplateVersion> versions(String name) {
    final String key = _require(name);
    return List<PromptTemplateVersion>.of(_templates[key]!.history);
  }

  /// Registers a new template. Rejects duplicate names, invalid names, empty
  /// or oversized bodies and includes that are unknown, self-referential,
  /// duplicated or cyclic.
  PromptTemplate create({
    required String name,
    required String body,
    List<String> includes = const <String>[],
    bool enabled = true,
    String? note,
  }) {
    final String key = _validateName(name);
    if (_templates.containsKey(key)) {
      throw PromptValidationException('DUPLICATE_NAME', key);
    }
    final String text = _validateBody(body);
    final List<String> includesList = _validateIncludes(key, includes);

    final DateTime now = clock.now();
    final PromptTemplateVersion first = PromptTemplateVersion(
      version: 1,
      body: text,
      createdAt: now,
      note: _note(note),
    );
    _templates[key] = PromptTemplate(
      name: key,
      body: text,
      version: 1,
      enabled: enabled,
      createdAt: now,
      updatedAt: now,
      history: <PromptTemplateVersion>[first],
      includes: includesList,
      redactions: _redact(text).kinds,
    );
    return _templates[key]!;
  }

  /// Writes a new revision. Omitting [body] keeps the current text; omitting
  /// [includes] keeps the current composition. A rejected update changes
  /// nothing.
  PromptTemplate update(
    String name, {
    String? body,
    List<String>? includes,
    String? note,
  }) {
    final String key = _require(name);
    final PromptTemplate existing = _templates[key]!;
    final String text = body == null ? existing.body : _validateBody(body);
    final List<String> includesList = includes == null
        ? existing.includes
        : _validateIncludes(key, includes);

    final DateTime now = clock.now();
    final int nextVersion = existing.version + 1;
    final PromptTemplate updated = existing.copyWith(
      body: text,
      version: nextVersion,
      updatedAt: now,
      history: <PromptTemplateVersion>[
        ...existing.history,
        PromptTemplateVersion(
          version: nextVersion,
          body: text,
          createdAt: now,
          note: _note(note),
        ),
      ],
      includes: includesList,
      redactions: _redact(text).kinds,
    );
    _templates[key] = updated;
    return updated;
  }

  /// Flips the enabled flag. This is not a content change, so it does not
  /// create a version.
  PromptTemplate setEnabled(String name, bool enabled) {
    final String key = _require(name);
    final PromptTemplate updated = _templates[key]!.copyWith(enabled: enabled);
    _templates[key] = updated;
    return updated;
  }

  bool delete(String name) {
    final String key = name.trim();
    if (!_templates.containsKey(key)) {
      return false;
    }
    _templates.remove(key);
    return true;
  }

  /// Renders the named template and everything it explicitly includes, then
  /// redacts the result. Nothing else is ever included.
  ///
  /// Throws when the root or any template in the chain is disabled, missing,
  /// or when a `{{placeholder}}` has no value.
  PromptComposition compose(
    String name, {
    Map<String, String> values = const <String, String>{},
  }) {
    final String key = _require(name);
    final List<PromptSection> sections = <PromptSection>[];
    final List<String> seen = <String>[];

    // Depth-first, declared order, each template emitted at most once — a
    // diamond in the include graph composes without repeating a body.
    void render(String current) {
      final PromptTemplate template = _templates[_require(current)]!;
      if (!template.enabled) {
        throw PromptValidationException('TEMPLATE_DISABLED', current);
      }
      if (seen.contains(current)) {
        return;
      }
      seen.add(current);
      for (final String included in template.includes) {
        if (!_templates.containsKey(included)) {
          throw PromptValidationException('UNKNOWN_INCLUDE', included);
        }
        render(included);
      }
      sections.add(
        PromptSection(
          name: current,
          version: template.version,
          text: template.body,
        ),
      );
    }

    render(key);

    final StringBuffer buffer = StringBuffer();
    final Set<String> redactions = <String>{};
    final List<String> order = <String>[];
    for (final PromptSection section in sections) {
      final RedactionResult substituted = _substitute(section.text, values);
      if (substituted.missing.isNotEmpty) {
        throw PromptValidationException(
          'UNRESOLVED_PLACEHOLDER',
          '${section.name}: ${substituted.missing.join(',')}',
        );
      }
      final RedactionResult redacted = _redact(substituted.text);
      redactions.addAll(redacted.kinds);
      order.add(section.name);
      buffer
        ..writeln('# ${section.name}')
        ..writeln(redacted.text)
        ..writeln();
    }

    final PromptTemplate root = _templates[key]!;
    return PromptComposition(
      root: key,
      version: root.version,
      order: order,
      sections: sections,
      text: buffer.toString().trimRight(),
      redactions: redactions.toList(),
    );
  }

  /// Removes anything that looks like a credential and returns the safe text.
  /// Static so callers can scrub text before it reaches a log or a model.
  static String redactSecrets(String text) => _redact(text).text;

  // --- internals ---------------------------------------------------------

  static RedactionResult _redact(String text) {
    var working = text;
    final List<String> kinds = <String>[];

    for (final _SecretPattern pattern in _secretPatterns) {
      if (!pattern.pattern.hasMatch(working)) {
        continue;
      }
      kinds.add(pattern.kind);
      working = working.replaceAll(
        pattern.pattern,
        '[redacted:${pattern.kind}]',
      );
    }
    return RedactionResult(text: working, kinds: kinds);
  }

  String _require(String name) {
    final String key = name.trim();
    final PromptTemplate? template = _templates[key];
    if (template == null) {
      throw PromptValidationException('UNKNOWN_NAME', key);
    }
    return key;
  }

  String _validateName(String name) {
    final String key = name.trim();
    if (key.isEmpty) {
      throw const PromptValidationException('INVALID_NAME');
    }
    if (!_namePattern.hasMatch(key)) {
      throw PromptValidationException('INVALID_NAME', key);
    }
    return key;
  }

  String _validateBody(String body) {
    final String text = body.trim();
    if (text.isEmpty) {
      throw const PromptValidationException('EMPTY_BODY');
    }
    if (text.length > maxBodyLength) {
      throw PromptValidationException('BODY_TOO_LONG', text.length.toString());
    }
    return text;
  }

  String? _note(String? note) {
    final String? trimmed = note?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  List<String> _validateIncludes(String owner, List<String> includes) {
    final List<String> out = <String>[];
    for (final String raw in includes) {
      final String included = raw.trim();
      if (included.isEmpty) {
        throw const PromptValidationException('INVALID_INCLUDE');
      }
      if (included == owner) {
        throw PromptValidationException('SELF_INCLUDE', included);
      }
      if (out.contains(included)) {
        throw PromptValidationException('DUPLICATE_INCLUDE', included);
      }
      if (!_templates.containsKey(included)) {
        throw PromptValidationException('UNKNOWN_INCLUDE', included);
      }
      out.add(included);
    }
    _rejectCycle(owner, out);
    return out;
  }

  /// Rejects any include edge that would close a loop, before it is stored.
  void _rejectCycle(String owner, List<String> includes) {
    final Map<String, List<String>> pending = <String, List<String>>{
      for (final PromptTemplate template in _templates.values)
        template.name: List<String>.of(template.includes),
      owner: List<String>.of(includes),
    };

    final Set<String> settled = <String>{};
    while (settled.length < pending.length) {
      bool progressed = false;
      for (final MapEntry<String, List<String>> entry in pending.entries) {
        if (settled.contains(entry.key)) {
          continue;
        }
        if (entry.value.every(settled.contains)) {
          settled.add(entry.key);
          progressed = true;
        }
      }
      if (!progressed) {
        final String stuck = pending.keys.firstWhere(
          (String key) => !settled.contains(key),
        );
        throw PromptValidationException('INCLUDE_CYCLE', stuck);
      }
    }
  }

  RedactionResult _substitute(String text, Map<String, String> values) {
    final Set<String> missing = <String>{};
    final String output = text.replaceAllMapped(_placeholder, (Match match) {
      final String key = match.group(1)!;
      final String? value = values[key];
      if (value == null) {
        missing.add(key);
        return match.group(0)!;
      }
      return value;
    });
    return RedactionResult(
      text: output,
      kinds: missing.toList(),
      missing: missing.toList(),
    );
  }
}

/// The outcome of a redaction or substitution pass.
class RedactionResult {
  const RedactionResult({
    required this.text,
    required this.kinds,
    this.missing = const <String>[],
  });

  final String text;

  /// Secret kinds that were replaced, in detection order.
  final List<String> kinds;

  /// Placeholders that had no value, in detection order.
  final List<String> missing;
}

class _SecretPattern {
  const _SecretPattern(this.kind, this.pattern);

  final String kind;
  final RegExp pattern;
}

/// Order matters: the widest shape is replaced first so a credential inside a
/// private key block is not partially rewritten.
final List<_SecretPattern> _secretPatterns = <_SecretPattern>[
  _SecretPattern(
    'privateKey',
    RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    ),
  ),
  _SecretPattern(
    'awsAccessKeyId',
    RegExp(r'\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{12,}\b'),
  ),
  _SecretPattern(
    'bearerToken',
    RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
  ),
  _SecretPattern(
    'apiKey',
    RegExp(
      r'\b(?:sk|pk|rk|ghp|gho|ghu|ghs|glpat|xox[abpsr]|AIza)[-_][A-Za-z0-9_-]{12,}',
    ),
  ),
  _SecretPattern(
    'genericSecret',
    RegExp(
      r'\b(?:api[_-]?key|apikey|secret|token|password|passwd|pwd'
      r'|access[_-]?token|client[_-]?secret|auth[_-]?token)\b'
      r'\s*(?:[:=]|is)\s*[\x22\x27]?[^\s\x22\x27]{4,}[\x22\x27]?',
      caseSensitive: false,
    ),
  ),
];
