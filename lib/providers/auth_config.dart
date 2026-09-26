/// Runtime provider configuration: base URL, credentials and extra headers.
library;

/// Base URL plus credentials for one OpenAI-compatible endpoint.
///
/// Nothing is hard-coded: the app supplies the base URL and API key at runtime,
/// so the same runtime works against a hosted gateway, a self-hosted server or
/// a local test double.
class ProviderAuthConfig {
  ProviderAuthConfig({
    required String baseUrl,
    String? apiKey,
    Map<String, String> headers = const <String, String>{},
    Map<String, String> query = const <String, String>{},
  }) : baseUrl = _normalizeBase(baseUrl),
       apiKey = _normalizeKey(apiKey),
       headers = Map<String, String>.unmodifiable(_sanitize(headers)),
       query = Map<String, String>.unmodifiable(query) {
    if (this.baseUrl.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must not be empty');
    }
    final Uri? parsed = Uri.tryParse(this.baseUrl);
    if (parsed == null ||
        (parsed.scheme != 'https' && parsed.scheme != 'http') ||
        parsed.host.isEmpty) {
      throw ArgumentError.value(
        this.baseUrl,
        'baseUrl',
        'must be an absolute http(s) URL',
      );
    }
  }

  /// Header names owned by the runtime; callers may not override them.
  static const Set<String> reservedHeaders = <String>{
    'authorization',
    'content-type',
    'accept',
  };

  /// Absolute base URL, without a trailing slash.
  final String baseUrl;

  /// API key, or `null` for endpoints that need no credentials.
  final String? apiKey;

  /// Extra headers sent with every request.
  final Map<String, String> headers;

  /// Query parameters merged into every request URL.
  final Map<String, String> query;

  /// Whether a credential is configured.
  bool get hasCredentials => apiKey != null;

  /// Resolves [path] against the base URL, merging [extraQuery].
  Uri resolve(String path, [Map<String, String>? extraQuery]) {
    final String relative = path.startsWith('/') ? path.substring(1) : path;
    final Uri base = Uri.parse('$baseUrl/$relative');
    return base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        ...query,
        ...?extraQuery,
      },
    );
  }

  /// Headers for a request; pass `streaming: true` for an SSE accept type.
  Map<String, String> requestHeaders({bool streaming = false}) {
    return <String, String>{
      if (apiKey != null) 'Authorization': 'Bearer $apiKey',
      'content-type': 'application/json',
      'accept': streaming ? 'text/event-stream' : 'application/json',
      ...headers,
    };
  }

  /// A copy with selected fields replaced.
  ProviderAuthConfig copyWith({
    String? baseUrl,
    String? apiKey,
    Map<String, String>? headers,
    Map<String, String>? query,
  }) => ProviderAuthConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    headers: headers ?? this.headers,
    query: query ?? this.query,
  );

  /// Log-safe description: the key is never included.
  String describe() {
    final String credential = apiKey == null
        ? 'no credential'
        : 'key ${_mask(apiKey!)}';
    return '$baseUrl ($credential)';
  }

  static String _normalizeBase(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  static String? _normalizeKey(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(value, 'apiKey', 'must not be blank');
    }
    return trimmed;
  }

  static Map<String, String> _sanitize(Map<String, String> headers) {
    for (final String name in headers.keys) {
      if (reservedHeaders.contains(name.toLowerCase())) {
        throw ArgumentError.value(
          name,
          'headers',
          'is reserved; use the apiKey field instead',
        );
      }
    }
    return headers;
  }

  static String _mask(String key) {
    if (key.length <= 4) return '***';
    return '${key.substring(0, 2)}…${key.substring(key.length - 2)}';
  }

  @override
  String toString() => 'ProviderAuthConfig(${describe()})';
}
