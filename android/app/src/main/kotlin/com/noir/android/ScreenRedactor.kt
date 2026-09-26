// android/app/src/main/kotlin/com/noir/android/ScreenRedactor.kt — R3 (pure)
//
// Deterministic redaction + size capping for everything that leaves
// AgentAccessibilityService toward the Dart runtime.
//
// PURE KOTLIN BY CONTRACT: no android.* imports, no clock, no randomness, no
// I/O. That is a hard requirement rather than a style choice — the unit tests in
// android/app/src/test/** run on a plain JVM where any framework call throws
// "not mocked", so every rule that has to be *provable* in a test has to live
// behind this boundary. It is also why redaction is a separate step from
// capture: the service must be able to demonstrate, in CI, that a captured
// secret cannot reach the MethodChannel.
//
// What is redacted: credential-shaped material (auth headers, JWTs, provider
// API keys, `password:`-style assignments, one-time codes, card-shaped digit
// runs, key blocks, long hex blobs).
//
// Known limit, stated plainly: a value with no credential SHAPE at all — no
// keyword, no scheme, no digit run, no key block — is indistinguishable from
// interface prose, so it is not redacted here. Catching it would mean
// redacting the visible text that the A6a sanitizer exists to read. That case
// belongs to the Dart sanitizer, which has the app context this side lacks.
//
// What is deliberately NOT redacted: names, e-mail addresses, phone numbers and
// ordinary prose. The A6a sanitizer in lib/safety/screen_content_sanitizer.dart
// detects prompt injection through *visible* text; over-redacting here would
// hide exactly the content it needs to see. This class removes credentials, not
// meaning.
package com.noir.android

/** How one redaction rule is expressed. Rules are applied in declaration order. */
private class SecretRule(val pattern: Regex, val replace: (MatchResult) -> String) {
  fun apply(input: String): String = pattern.replace(input, replace)
}

object ScreenRedactor {

  /** Stable marker. Deliberately not a valid credential shape, so a second
   *  redaction pass over an already-redacted string is a no-op. */
  const val REDACTED = "[redacted]"

  /** Appended when a field is longer than the cap. */
  const val TRUNCATION_MARKER = "[truncated]"

  /** Cap for a single text field in a node dump. */
  const val MAX_FIELD_CHARS = 512

  /** Cap for one whole payload (all nodes) in characters. */
  const val MAX_PAYLOAD_CHARS = 24_000

  /** Cap for the node count in one payload, independent of the char budget. */
  const val MAX_NODES_PER_PAYLOAD = 400

  private val SECRET_RULES: List<SecretRule> = listOf(
    // --- key material ---------------------------------------------------------
    SecretRule(
      Regex("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----")
    ) { "-----BEGIN PRIVATE KEY----- $REDACTED -----END PRIVATE KEY-----" },

    // --- authorization headers ------------------------------------------------
    SecretRule(Regex("(?i)\\b(bearer|basic|token)\\s+[A-Za-z0-9\\-._~+/]{12,}=*")) { m ->
      m.groupValues[1] + " " + REDACTED
    },

    // --- JWT (the header segment of a real JWT is base64 of `{"`) ------------
    SecretRule(Regex("\\beyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}")) {
      REDACTED
    },

    // --- provider-shaped API keys --------------------------------------------
    SecretRule(Regex("\\b(?:AKIA[0-9A-Z]{16}|(?:sk|pk|rk|xox[abpsr]|gh[pousr]|glpat)[-_][A-Za-z0-9_-]{12,})\\b")) {
      REDACTED
    },

    // --- quoted assignment, e.g. {"api_key": "..."} ---------------------------
    SecretRule(
      Regex(
        "(?i)\"([A-Za-z0-9_.\\- ]{0,40}(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|" +
          "authorization|otp|pin|private[_-]?key|credential|session|cvv|cvc|ssn)" +
          "[A-Za-z0-9_.\\- ]{0,20})\"\\s*:\\s*\"[^\"]*\""
      )
    ) { m -> "\"" + m.groupValues[1] + "\": \"" + REDACTED + "\"" },

    // --- bare assignment, e.g. password = hunter2 -----------------------------
    //
    // The value alternatives matter more than they look:
    //   * `[^...]+` deliberately stops at `]`, so a value such as
    //     `token: [redacted]` produced by an earlier rule must be matched WHOLE
    //     (the `\[[^\]]*\]` branch) or the trailing bracket would survive and
    //     re-redaction would keep appending to it. Redaction has to be
    //     idempotent: every node can be sanitized more than once.
    //   * the scheme-word lookahead stops `Authorization: Bearer <token>` from
    //     being treated as `Authorization: <redacted> <token>`, which would
    //     leave the token in the clear. The header rule above owns that shape.
    SecretRule(
      Regex(
        "(?i)\\b([A-Za-z0-9_.\\- ]{0,40}(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|" +
          "authorization|otp|pin|private[_-]?key|credential)" +
          "[A-Za-z0-9_.\\- ]{0,20})(\\s*[:=]\\s*)" +
          "(?:\"[^\"]*\"|'[^']*'|\\[[^\\]]*\\]|(?!(?:bearer|basic|token|digest)\\b)[^\\s,;)\\]}]+)"
      )
    ) { m -> m.groupValues[1] + m.groupValues[2] + REDACTED },

    // --- spoken one-time codes ------------------------------------------------
    SecretRule(
      Regex(
        "(?i)\\b(otp|one[ -]?time (?:code|password)|verification code|security code|2fa code|pin)" +
          "\\b(\\s*(?:is\\b|number\\b|:|=|#)?\\s*)(\\d{4,8})\\b"
      )
    ) { m -> m.groupValues[1] + m.groupValues[2] + REDACTED },

    // --- card-shaped digit runs ----------------------------------------------
    SecretRule(Regex("\\b\\d{4}[ -]\\d{4}[ -]\\d{4}[ -]\\d{4}\\b|(?:\\d[ -]?){13,19}\\b")) {
      REDACTED
    },

    // --- long hex blobs (hashes, seeds, keys) --------------------------------
    SecretRule(Regex("\\b[A-Fa-f0-9]{32,}\\b")) { REDACTED }
  )

  /** Applies every rule, in order, to [text]. */
  fun redactSecrets(text: String): String {
    if (text.isEmpty()) return text
    var result = text
    for (rule in SECRET_RULES) result = rule.apply(result)
    return result
  }

  /**
   * Truncates [text] so `result.length <= maxChars`.
   *
   * The result is either the input (already short enough) or a prefix followed
   * by [TRUNCATION_MARKER]; the total never exceeds the cap, so a caller can
   * budget with the cap alone.
   */
  fun capChars(text: String, maxChars: Int): String {
    if (maxChars <= 0) return ""
    if (text.length <= maxChars) return text
    if (maxChars <= TRUNCATION_MARKER.length) return text.take(maxChars)
    return text.take(maxChars - TRUNCATION_MARKER.length) + TRUNCATION_MARKER
  }

  /** Redact, trim and cap one text field. `null` and blank become `""`. */
  fun redactField(text: String?, fieldCap: Int = MAX_FIELD_CHARS): String {
    if (text == null) return ""
    val trimmed = text.trim()
    if (trimmed.isEmpty()) return ""
    return capChars(redactSecrets(trimmed), fieldCap)
  }

  /** One sanitized node plus how many fields had to be rewritten. */
  data class SanitizedNode(val node: Map<String, Any?>, val redactions: Int)

  /**
   * Sanitizes one node.
   *
   * EVERY string value is redacted, not just `text` / `contentDescription`: a
   * hostile app can put a credential in any field it likes, and this class is
   * the last place before the value crosses the channel.
   */
  fun sanitizeNode(node: Map<String, Any?>, fieldCap: Int = MAX_FIELD_CHARS): SanitizedNode {
    var redactions = 0
    val out = LinkedHashMap<String, Any?>(node.size)
    for ((key, value) in node) out[key] = sanitizeValue(value, fieldCap) { redactions++ }
    return SanitizedNode(out, redactions)
  }

  private fun sanitizeValue(value: Any?, fieldCap: Int, onRedaction: () -> Unit): Any? =
    when (value) {
      null -> null
      is String -> {
        val redacted = redactSecrets(value)
        if (redacted != value) onRedaction()
        capChars(redacted, fieldCap)
      }
      is CharSequence -> sanitizeValue(value.toString(), fieldCap, onRedaction)
      is Map<*, *> -> {
        val nested = LinkedHashMap<Any?, Any?>(value.size)
        for ((nestedKey, nestedValue) in value) {
          nested[nestedKey] = sanitizeValue(nestedValue, fieldCap, onRedaction)
        }
        nested
      }
      is Iterable<*> -> value.map { sanitizeValue(it, fieldCap, onRedaction) }
      else -> value
    }

  /**
   * Deterministic, codec-independent size estimate of a node payload, in
   * characters. Overestimates the wire size, which is the safe direction for a
   * cap: the budget is spent before the payload can be too large, not after.
   */
  fun sizeOfValue(value: Any?): Int = when (value) {
    null -> 4
    is String -> value.length + 2
    is CharSequence -> value.length + 2
    is Boolean, is Int, is Long, is Short, is Byte, is Float, is Double -> 4
    is Map<*, *> -> 2 + value.entries.sumOf { sizeOfValue(it.key) + sizeOfValue(it.value) }
    is Iterable<*> -> 2 + value.sumOf { sizeOfValue(it) }
    is Array<*> -> 2 + value.sumOf { sizeOfValue(it) }
    else -> 8
  }

  /** A node payload that has passed redaction and both caps. */
  data class NodePayload(
    val nodes: List<Map<String, Any?>>,
    val keptNodes: Int,
    val droppedNodes: Int,
    val redactedFields: Int,
    val charSize: Int,
    val truncated: Boolean
  ) {
    val isEmpty: Boolean get() = nodes.isEmpty()

    /** Reply shape. The first four keys are the historical contract read by
     *  lib/platform/native_bridge.dart; the rest are additive transparency. */
    fun toEnvelope(capturedAtMs: Long, source: String): Map<String, Any?> = mapOf(
      "nodes" to ArrayList<Map<String, Any?>>(nodes),
      "nodeCount" to nodes.size,
      "capturedAtMs" to capturedAtMs,
      "source" to source,
      "redactedFields" to redactedFields,
      "droppedNodes" to droppedNodes,
      "charSize" to charSize,
      "truncated" to truncated
    )
  }

  /**
   * Redacts every node, then applies the node-count and char caps.
   *
   * Nothing is discarded silently: `droppedNodes` counts every node that did not
   * fit, and the service surfaces it in `serviceStatus` and in the push.
   */
  fun sanitizeNodes(
    nodes: List<Map<String, Any?>>,
    fieldCap: Int = MAX_FIELD_CHARS,
    maxNodes: Int = MAX_NODES_PER_PAYLOAD,
    maxChars: Int = MAX_PAYLOAD_CHARS
  ): NodePayload {
    val kept = ArrayList<Map<String, Any?>>(minOf(nodes.size, maxNodes.coerceAtLeast(0)))
    var dropped = 0
    var redactions = 0
    var size = 0
    for (node in nodes) {
      if (kept.size >= maxNodes) {
        dropped++
        continue
      }
      val sanitized = sanitizeNode(node, fieldCap)
      val nodeSize = sizeOfValue(sanitized.node)
      if (size + nodeSize > maxChars) {
        dropped++
        continue
      }
      kept.add(sanitized.node)
      size += nodeSize
      redactions += sanitized.redactions
    }
    return NodePayload(
      nodes = kept,
      keptNodes = kept.size,
      droppedNodes = dropped,
      redactedFields = redactions,
      charSize = size,
      truncated = dropped > 0
    )
  }
}
