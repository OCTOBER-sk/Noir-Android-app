import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../llm_provider.dart';

/// Adapter for the OpenRouter free-tier model `poolside/laguna-s-2.1:free`.
///
/// Reads its API key from the runtime `--dart-define=OPENROUTER_API_KEY`
/// value; the key is never hardcoded in source.
class OpenRouterAdapter implements LLMProvider {
  /// OpenRouter chat completions endpoint.
  static const String endpoint =
      'https://openrouter.ai/api/v1/chat/completions';

  /// Capabilities advertised by the OpenRouter free-tier model.
  @override
  final LLMProviderCapabilities capabilities = const LLMProviderCapabilities(
    streaming: true,
    vision: false,
    toolUse: false,
    contextWindow: 262144,
    costPerMillionInput: 0.0,
    costPerMillionOutput: 0.0,
  );

  @override
  String get name => 'OpenRouter';

  @override
  String get model => openrouterPoolsideFree;

  /// Bearer API key injected via `--dart-define=OPENROUTER_API_KEY`.
  final String apiKey;

  /// HTTP client used for streaming requests (injectable for tests).
  final http.Client client;

  /// Creates an [OpenRouterAdapter] with the given [apiKey] and [client].
  OpenRouterAdapter({required this.apiKey, http.Client? client})
      : client = client ?? http.Client();

  @override
  Stream<String> streamChat(List<ChatMessage> messages) async* {
    final request = http.Request('POST', Uri.parse(endpoint));
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'model': model,
      'stream': true,
      'messages': [
        for (final m in messages) {'role': m.role, 'content': m.content},
      ],
    });

    final response = await client.send(request);
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final data = trimmed.substring(5).trim();
      if (data == '[DONE]') break;
      final decoded = jsonDecode(data) as Map<String, dynamic>;
      final rawChoices = decoded['choices'];
      if (rawChoices is! List) continue;
      final choices = rawChoices;
      if (choices.isEmpty) continue;
      final delta = (choices.first as Map<String, dynamic>)['delta'];
      if (delta == null) continue;
      final content =
          (delta as Map<String, dynamic>)['content'] as String?;
      if (content != null) {
        yield content;
      }
    }
  }
}
