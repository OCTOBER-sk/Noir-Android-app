// lib/data/provider_settings.dart — provider configuration that cannot leak.
//
// A [ProviderSettings] record holds a reference to a secret, never the secret.
// Three representations exist and they are deliberately different:
//   * [toJson]        — what gets persisted. No plaintext, ever.
//   * [toRedactedJson] — what gets shown or exported. The reference is replaced
//     by a placeholder and presence is reported as a boolean.
//   * [toString]     — safe for logs, says only that a secret is configured.

import 'codecs.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'records.dart';
import 'secrets.dart';

/// The suffix that makes a provider's secret reference predictable.
const String providerSecretSuffix = '-api-key';

/// The reference a provider's API key is stored under.
String providerSecretRef(String providerId) =>
    '$providerId$providerSecretSuffix';

/// How a secret is stored, per provider.
class ProviderSettings extends DataRecord {
  ProviderSettings({
    required super.id,
    required this.displayName,
    required this.baseUrl,
    required this.defaultModel,
    required List<String> fallbackModels,
    required this.funded,
    required this.rpmCap,
    required this.dailyCap,
    required super.createdAt,
    required super.updatedAt,
    this.secretRef,
    this.secretUpdatedAt,
  }) : fallbackModels = List<String>.unmodifiable(fallbackModels) {
    validate();
  }

  final String displayName;
  final String baseUrl;
  final String defaultModel;
  final List<String> fallbackModels;

  /// Whether the account is funded, which decides the daily cap that applies.
  final bool funded;
  final int rpmCap;
  final int dailyCap;

  /// The secret store reference for this provider's key. Never a value.
  final String? secretRef;
  final DateTime? secretUpdatedAt;

  /// Whether a secret has been filed for this provider.
  bool get hasSecret => secretRef != null && secretRef!.isNotEmpty;

  /// The value of [secretRef], or null. Present so callers cannot be tempted to
  /// reach for a field that holds plaintext.
  String? get secretValue => null;

  /// Semantic validation, applied wherever a settings record is built.
  void validate() {
    if (displayName.trim().isEmpty) {
      throw const InvalidDataError('a provider needs a display name');
    }
    if (!isValidBaseUrl(baseUrl)) {
      throw InvalidDataError('"$baseUrl" is not an http(s) base URL');
    }
    if (defaultModel.trim().isEmpty) {
      throw const InvalidDataError('a provider needs a default model');
    }
    if (rpmCap < 0) {
      throw InvalidDataError('rpmCap must not be negative, got $rpmCap');
    }
    if (dailyCap < 0) {
      throw InvalidDataError('dailyCap must not be negative, got $dailyCap');
    }
    if (secretRef != null && secretRef!.isNotEmpty) {
      checkedSecretRef(secretRef!);
    }
  }

  /// Whether [value] can be used as a provider base URL.
  static bool isValidBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }

  ProviderSettings copyWith({
    String? displayName,
    String? baseUrl,
    String? defaultModel,
    List<String>? fallbackModels,
    bool? funded,
    int? rpmCap,
    int? dailyCap,
    DateTime? updatedAt,
    String? secretRef,
    bool clearSecretRef = false,
    DateTime? secretUpdatedAt,
    bool clearSecretUpdatedAt = false,
  }) {
    return ProviderSettings(
      id: id,
      displayName: displayName ?? this.displayName,
      baseUrl: baseUrl ?? this.baseUrl,
      defaultModel: defaultModel ?? this.defaultModel,
      fallbackModels: fallbackModels ?? this.fallbackModels,
      funded: funded ?? this.funded,
      rpmCap: rpmCap ?? this.rpmCap,
      dailyCap: dailyCap ?? this.dailyCap,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      secretRef: clearSecretRef ? null : (secretRef ?? this.secretRef),
      secretUpdatedAt: clearSecretUpdatedAt
          ? null
          : (secretUpdatedAt ?? this.secretUpdatedAt),
    );
  }

  /// The persisted form. Contains a reference, never a value.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'displayName': displayName,
      'baseUrl': baseUrl,
      'defaultModel': defaultModel,
      'fallbackModels': List<String>.of(fallbackModels),
      'funded': funded,
      'rpmCap': rpmCap,
      'dailyCap': dailyCap,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
    if (hasSecret) {
      json['secretRef'] = secretRef;
      if (secretUpdatedAt != null) {
        json['secretUpdatedAt'] = secretUpdatedAt!.toUtc().toIso8601String();
      }
    }
    return json;
  }

  /// The redacted form: everything except the reference, plus presence.
  Map<String, Object?> toRedactedJson() {
    final json = toJson();
    if (json.containsKey('secretRef')) {
      json['secretRef'] = redactedSecretPlaceholder;
    }
    json['secretConfigured'] = hasSecret;
    return json;
  }

  @override
  String toString() =>
      'ProviderSettings($id, "$displayName", $baseUrl, '
      'model: $defaultModel, funded: $funded, rpmCap: $rpmCap, '
      'dailyCap: $dailyCap, ${describeSecret(secretRef ?? '-', present: hasSecret)})';
}

/// Reads and writes [ProviderSettings] records.
class ProviderSettingsCodec extends RecordCodec<ProviderSettings> {
  const ProviderSettingsCodec();

  @override
  Map<String, Object?> encode(ProviderSettings record) => record.toJson();

  @override
  ProviderSettings decode(String id, Map<String, Object?> json) {
    const collection = NoirCollections.providerSettings;
    final displayName = requireString(json, 'displayName', collection, id);
    final baseUrl = requireString(json, 'baseUrl', collection, id);
    final defaultModel = requireString(json, 'defaultModel', collection, id);
    final fallbackModels = requireStringList(
      json,
      'fallbackModels',
      collection,
      id,
    );
    final funded = optionalBool(json, 'funded', collection, id);
    final rpmCap = requireInt(json, 'rpmCap', collection, id);
    final dailyCap = requireInt(json, 'dailyCap', collection, id);
    final createdAt = requireTimestamp(json, 'createdAt', collection, id);
    final updatedAt = requireTimestamp(json, 'updatedAt', collection, id);
    if (!ProviderSettings.isValidBaseUrl(baseUrl)) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'baseUrl',
        detail: 'not an http(s) URL: "$baseUrl"',
      );
    }
    final secretRef = optionalString(json, 'secretRef');
    final secretUpdatedAt = json.containsKey('secretUpdatedAt')
        ? requireTimestamp(json, 'secretUpdatedAt', collection, id)
        : null;

    try {
      return ProviderSettings(
        id: id,
        displayName: displayName,
        baseUrl: baseUrl,
        defaultModel: defaultModel,
        fallbackModels: fallbackModels,
        funded: funded,
        rpmCap: rpmCap,
        dailyCap: dailyCap,
        createdAt: createdAt,
        updatedAt: updatedAt,
        secretRef: secretRef,
        secretUpdatedAt: secretUpdatedAt,
      );
    } on InvalidDataError catch (error) {
      // The field is named by the codec where it can be; anything the codec
      // already checked is re-reported as a shape error for the record.
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'value',
        detail: error.message,
        cause: error,
      );
    }
  }
}
