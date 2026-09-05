import 'skill_proposal.dart';

/// In-memory skill repository (V2.1 §A3 thin).
///
/// Stores [Skill] definitions with simple CRUD access, partitioned for the
/// eventual separate Skills store. Persists only for the lifetime of the
/// isolate.
class SkillRepository {
  final List<Skill> _skills = [];

  /// Adds [skill] to the repository.
  void add(Skill skill) {
    // Avoid duplicate ids.
    _skills.removeWhere((s) => s.id == skill.id);
    _skills.add(skill);
  }

  /// Returns the [Skill] with the given [id], or `null` if absent.
  Skill? get(String id) {
    for (final skill in _skills) {
      if (skill.id == id) return skill;
    }
    return null;
  }

  /// Returns all stored skills (insertion order).
  List<Skill> getAll() => List<Skill>.unmodifiable(_skills);

  /// Removes the [Skill] with the given [id]. Returns `true` if removed.
  bool remove(String id) {
    final before = _skills.length;
    _skills.removeWhere((s) => s.id == id);
    return _skills.length < before;
  }

  /// Removes every stored skill.
  void clear() {
    _skills.clear();
  }
}
