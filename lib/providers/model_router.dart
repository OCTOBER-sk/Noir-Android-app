import 'llm_provider.dart';

/// Trivial pass-through router that exposes a single [LLMProvider].
///
/// The full multi-provider router is a later concern; this thin slice
/// returns the configured provider for any routing request.
class ModelRouter {
  /// The single provider this router delegates to.
  final LLMProvider provider;

  /// Creates a [ModelRouter] wrapping [provider].
  ModelRouter(this.provider);

  /// Returns the provider this router delegates to.
  LLMProvider route() => provider;
}
