/// The six memory layers of the Noir agent memory model (V2.1 §A1).
///
/// Ordered from most ephemeral to most durable/abstract. Each [MemoryItem]
/// is stamped with one of these layers at creation time.
enum MemoryLayer {
  /// Raw, immediate sensory observations (short-lived).
  sensory,

  /// Transient working context for the current turn/session.
  shortTerm,

  /// Personal events and task outcomes with timestamps.
  episodic,

  /// Durable, confidence-weighted knowledge about the world.
  semantic,

  /// Reusable procedural playbooks (skills) stored as procedures.
  procedural,

  /// Self-referential reasoning about policies, risk, and trust.
  meta,
}
