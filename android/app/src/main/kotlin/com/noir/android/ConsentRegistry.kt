// android/app/src/main/kotlin/com/noir/android/ConsentRegistry.kt — R1 (pure)
//
// User-initiated, bounded, consent-based automation state.
//
// PURE KOTLIN BY CONTRACT: no android.* imports, and the clock is injected, so
// android/app/src/test/** can drive expiry, replay and refusal deterministically
// without sleeping.
//
// The rule this file exists to enforce: NO automation without an explicit,
// live, unspent user request token. A gesture with no token is not queued,
// retried or "probably fine" — it is refused (default deny), and the refusal is
// counted so it is visible in `serviceStatus` rather than swallowed.
package com.noir.android

/** Why a consent token was refused. `code` is a wire-stable MethodChannel code. */
enum class ConsentDenial(val code: String) {
  /** No token was presented at all. The default. */
  NO_TOKEN("CONSENT_REQUIRED"),

  /** A token that this registry never minted, or one already pruned. */
  UNKNOWN_TOKEN("CONSENT_UNKNOWN_TOKEN"),

  /** Past `expiresAtMs`. */
  EXPIRED("CONSENT_EXPIRED"),

  /** Explicitly ended by the user, or evicted by the live-token cap. */
  REVOKED("CONSENT_REVOKED"),

  /** Every permitted use has been spent: a replay. */
  EXHAUSTED("CONSENT_EXHAUSTED")
}

/**
 * A single, short-lived, use-bounded grant of permission to act.
 *
 * Two liveness questions, deliberately distinct:
 *
 *   * [isValidAt] — "was this grant still inside its window and not revoked?"
 *     Checks this *after* a use was spent, so a single-use token remains
 *     dispatchable for the action it was spent on.
 *   * [isLiveAt] — [isValidAt] *and* has an unspent use left. This is what
 *     "is there a live user request right now?" means.
 */
data class ConsentToken(
  val id: String,
  val kind: String,
  val issuedAtMs: Long,
  val expiresAtMs: Long,
  val maxUses: Int,
  val usesRemaining: Int = maxUses,
  val revoked: Boolean = false
) {
  val ttlMs: Long get() = expiresAtMs - issuedAtMs

  fun isValidAt(nowMs: Long): Boolean = !revoked && nowMs <= expiresAtMs

  fun isLiveAt(nowMs: Long): Boolean = isValidAt(nowMs) && usesRemaining > 0

  fun toMap(nowMs: Long): Map<String, Any?> = mapOf(
    "userRequestToken" to id,
    "kind" to kind,
    "issuedAtMs" to issuedAtMs,
    "expiresAtMs" to expiresAtMs,
    "expiresInMs" to (expiresAtMs - nowMs),
    "maxUses" to maxUses,
    "usesRemaining" to usesRemaining,
    "revoked" to revoked
  )
}

/** Result of presenting a token to the registry. */
sealed class ConsentResult {
  data class Granted(val token: ConsentToken) : ConsentResult()

  data class Denied(val denial: ConsentDenial, val message: String) : ConsentResult()

  val isGranted: Boolean get() = this is Granted

  val tokenOrNull: ConsentToken? get() = (this as? Granted)?.token
}

/**
 * Bounded store of live user-request tokens.
 *
 * Bounded in three independent ways, so an unattended service cannot accumulate
 * authority: [ttlMs] (time), [defaultMaxUses] (per request) and
 * [maxLiveTokens] (across requests — minting past the cap revokes the oldest
 * rather than growing the set).
 */
class ConsentRegistry(
  private val ttlMs: Long = DEFAULT_TTL_MS,
  private val defaultMaxUses: Int = DEFAULT_MAX_USES,
  private val maxLiveTokens: Int = MAX_LIVE_TOKENS,
  private val clock: () -> Long = { System.currentTimeMillis() }
) {
  private val lock = Any()
  private val tokens = LinkedHashMap<String, ConsentToken>()

  private var sequence = 0
  private var mintedCount = 0
  private var consumedCount = 0
  private var deniedCount = 0
  private val denialReasons = LinkedHashMap<String, Int>()

  init {
    require(ttlMs > 0) { "ConsentRegistry ttlMs must be > 0, was $ttlMs" }
    require(defaultMaxUses > 0) { "ConsentRegistry defaultMaxUses must be > 0, was $defaultMaxUses" }
    require(maxLiveTokens > 0) { "ConsentRegistry maxLiveTokens must be > 0, was $maxLiveTokens" }
  }

  /**
   * Issues a new user request token.
   *
   * Minting prunes dead tokens first and, if the live set is still full, revokes
   * the oldest so authority stays bounded.
   */
  fun mint(kind: String, maxUses: Int = defaultMaxUses, ttlMs: Long = this.ttlMs): ConsentToken =
    synchronized(lock) {
      pruneLocked()
      val now = clock()
      sequence++
      val uses = maxUses.coerceIn(1, maxLiveTokens)
      val window = ttlMs.coerceAtLeast(1L)
      val token = ConsentToken(
        id = "$kind-$sequence",
        kind = kind,
        issuedAtMs = now,
        expiresAtMs = now + window,
        maxUses = uses
      )
      while (tokens.size >= maxLiveTokens) {
        val oldest = tokens.keys.firstOrNull() ?: break
        tokens.remove(oldest)
      }
      tokens[token.id] = token
      mintedCount++
      token
    }

  /**
   * Spends one use of [id] and returns the post-consumption grant.
   *
   * A `null` or blank id is [ConsentDenial.NO_TOKEN]: the default-deny path.
   * Unknown, expired, revoked and already-spent tokens are all refusals, and a
   * spent token can never be revived.
   */
  fun consume(id: String?): ConsentResult = synchronized(lock) {
    val now = clock()
    if (id == null || id.isBlank()) {
      return denyLocked(ConsentDenial.NO_TOKEN, "no explicit user request token; refusing by default")
    }
    val current = tokens[id]
    if (current == null) {
      return denyLocked(ConsentDenial.UNKNOWN_TOKEN, "user request token $id is not live")
    }
    if (current.revoked) {
      return denyLocked(ConsentDenial.REVOKED, "user request token $id was ended by the user")
    }
    if (now > current.expiresAtMs) {
      return denyLocked(ConsentDenial.EXPIRED, "user request token $id expired")
    }
    if (current.usesRemaining <= 0) {
      return denyLocked(ConsentDenial.EXHAUSTED, "user request token $id was already spent; refusing replay")
    }
    val spent = current.copy(usesRemaining = current.usesRemaining - 1)
    tokens[id] = spent
    consumedCount++
    ConsentResult.Granted(spent)
  }

  /** Records a refusal that did not come from [consume] (e.g. a request with no
   *  `confirmed` flag at all), so the counters stay complete. */
  fun deny(denial: ConsentDenial, message: String): ConsentResult =
    synchronized(lock) { denyLocked(denial, message) }

  fun revoke(id: String): Boolean = synchronized(lock) {
    val current = tokens[id] ?: return false
    tokens[id] = current.copy(revoked = true)
    true
  }

  /** Ends every outstanding request. Called when the user leaves the app. */
  fun revokeAll(): Int = synchronized(lock) {
    val count = tokens.size
    for (id in tokens.keys.toList()) {
      val current = tokens.getValue(id)
      tokens[id] = current.copy(revoked = true)
    }
    count
  }

  /** Forgets dead tokens and returns how many were forgotten. */
  fun prune(): Int = synchronized(lock) { pruneLocked() }

  fun activeTokens(): List<ConsentToken> = synchronized(lock) {
    val now = clock()
    tokens.values.filter { it.isLiveAt(now) }
  }

  fun activeCount(): Int = activeTokens().size

  fun stats(): Map<String, Any?> = synchronized(lock) {
    val now = clock()
    mapOf(
      "minted" to mintedCount,
      "consumed" to consumedCount,
      "denied" to deniedCount,
      "active" to tokens.values.count { it.isLiveAt(now) },
      "ttlMs" to ttlMs,
      "maxUses" to defaultMaxUses,
      "maxLiveTokens" to maxLiveTokens,
      "denialReasons" to LinkedHashMap(denialReasons)
    )
  }

  private fun pruneLocked(): Int {
    val now = clock()
    val dead = tokens.values.filter { !it.isLiveAt(now) }.map { it.id }
    for (id in dead) tokens.remove(id)
    return dead.size
  }

  private fun denyLocked(denial: ConsentDenial, message: String): ConsentResult {
    deniedCount++
    denialReasons[denial.name] = (denialReasons[denial.name] ?: 0) + 1
    return ConsentResult.Denied(denial, message)
  }

  companion object {
    /** Long enough for a confirmation prompt, short enough that a stale
     *  confirmation cannot be replayed minutes later. */
    const val DEFAULT_TTL_MS = 15_000L

    /** One user request buys one gated action. */
    const val DEFAULT_MAX_USES = 1

    const val MAX_LIVE_TOKENS = 8
  }
}
