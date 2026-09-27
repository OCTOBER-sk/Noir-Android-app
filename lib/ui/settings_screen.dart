// lib/ui/settings_screen.dart — the only screen that can configure Noir.
//
// Why this file exists at all: Noir had 27,000+ lines of backend behind a
// composition root that reads the user's provider settings and refuses to
// invent one. `SettingsRepository.setSecret` had zero callers outside tests,
// so a real user had no way to enter an API key, which meant no provider, no
// model, no chat, no memory, no tools and no automations. Every one of those
// subsystems was implemented, unit-tested and unreachable.
//
// This screen is the missing writer. It calls the real repositories — it does
// not hold a parallel copy of configuration, and it never sees a stored
// secret value: the API key goes straight from the field into
// [SettingsRepository.setSecret] and the screen only ever learns *whether* a
// secret is present, via [ProviderSettings.hasSecret].
//
// Design: the V2.3 UI spec's seven monochrome tokens only, no accent colors,
// no new hex values.

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/noir_theme.dart';
import '../data/data.dart';

/// Configuration for Noir, backed by the real repositories.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    this.onProviderSaved,
  });

  /// The real provider settings repository. Not optional: a settings screen
  /// that cannot save anything is worse than no settings screen.
  final SettingsRepository settings;

  /// Called after a provider record or its secret is written, so the graph can
  /// rebuild its provider runtime instead of staying on a stale one.
  final Future<void> Function()? onProviderSaved;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ProviderSettings? _current;
  bool _loading = true;
  bool _saving = false;
  String? _problem;

  final TextEditingController _displayName = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _displayName.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  /// Reads the providers that really exist. A store that cannot be read is
  /// reported as a problem, not as an empty form.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _problem = null;
    });
    try {
      final List<ProviderSettings> all = await widget.settings.readAll();
      if (!mounted) return;
      setState(() {
        _current = all.isEmpty ? null : all.first;
        _loading = false;
        if (_current != null) _fill(_current!);
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _problem = 'The settings store could not be read: $error';
      });
    }
  }

  void _fill(ProviderSettings provider) {
    _displayName.text = provider.displayName;
    _baseUrl.text = provider.baseUrl;
    _model.text = provider.defaultModel;
    // The key is never read back into the field. There is nothing to read:
    // the record holds a reference, not a value.
    _apiKey.clear();
  }

  /// Writes the record and, when a key was typed, its secret. Both go through
  /// the repositories' own validation, so an invalid base URL or a blank model
  /// is reported by the layer that owns the rule rather than re-implemented
  /// here.
  Future<void> _save() async {
    final String key = _apiKey.text.trim();
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      final DateTime now = DateTime.now().toUtc();
      final String id = _current?.id ?? 'primary';
      await widget.settings.upsert(
        ProviderSettings(
          id: id,
          displayName: _displayName.text.trim().isEmpty
              ? 'My provider'
              : _displayName.text.trim(),
          baseUrl: _baseUrl.text.trim(),
          defaultModel: _model.text.trim(),
          fallbackModels: _current?.fallbackModels ?? const <String>[],
          funded: _current?.funded ?? false,
          rpmCap: _current?.rpmCap ?? 20,
          dailyCap: _current?.dailyCap ?? 50,
          createdAt: _current?.createdAt ?? now,
          updatedAt: now,
        ),
      );
      if (key.isNotEmpty) {
        await widget.settings.setSecret(id, key);
      }
      final ProviderSettings saved = (await widget.settings.find(id))!;
      if (!mounted) return;
      setState(() {
        _current = saved;
        _saving = false;
        _fill(saved);
      });
      await widget.onProviderSaved?.call();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _problem = 'Not saved: $error';
      });
    }
  }

  Future<void> _forgetKey() async {
    final ProviderSettings? current = _current;
    if (current == null) return;
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      await widget.settings.clearSecret(current.id);
      final ProviderSettings saved = (await widget.settings.find(current.id))!;
      if (!mounted) return;
      setState(() {
        _current = saved;
        _saving = false;
        _fill(saved);
      });
      await widget.onProviderSaved?.call();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _problem = 'The stored key was not removed: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NoirColors.pureBlack,
      appBar: AppBar(
        backgroundColor: NoirColors.pureBlack,
        foregroundColor: NoirColors.pureWhite,
        title: const Text('Settings'),
      ),
      body: _loading
          ? const Center(
              child: Text(
                'Reading your settings…',
                style: TextStyle(color: NoirColors.textMuted),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: <Widget>[
                const _SectionLabel('Provider'),
                const SizedBox(height: 8),
                const Text(
                  'Noir talks to an OpenAI-compatible endpoint you choose. It '
                  'ships with no default endpoint and no default key.',
                  style: TextStyle(color: NoirColors.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 16),
                _Field(
                  controller: _displayName,
                  label: 'Display name',
                  hint: 'My provider',
                ),
                _Field(
                  controller: _baseUrl,
                  label: 'Base URL',
                  hint: 'https://api.example.com/v1',
                ),
                _Field(
                  controller: _model,
                  label: 'Default model',
                  hint: 'the model id this provider serves',
                ),
                _Field(
                  controller: _apiKey,
                  label: 'API key',
                  hint: _current != null && _current!.hasSecret
                      ? 'A key is saved. Type to replace it.'
                      : 'Paste the key this provider issued you',
                  obscure: true,
                ),
                const SizedBox(height: 8),
                Text(
                  _current != null && _current!.hasSecret
                      ? 'A key is saved for this provider. The value is held by '
                            'the secret store and is never shown again.'
                      : 'No key saved yet, so Noir has no provider to call.',
                  style: const TextStyle(
                    color: NoirColors.textMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 20),
                if (_problem != null) ...<Widget>[
                  Text(
                    _problem!,
                    style: const TextStyle(color: NoirColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: NoirColors.pureWhite,
                          foregroundColor: NoirColors.pureBlack,
                        ),
                        child: Text(_saving ? 'Saving…' : 'Save'),
                      ),
                    ),
                    if (_current != null && _current!.hasSecret) ...<Widget>[
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: _saving ? null : _forgetKey,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: NoirColors.textSecondary,
                          side: const BorderSide(
                            color: NoirColors.surfaceDark2,
                          ),
                        ),
                        child: const Text('Forget key'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: NoirColors.pureWhite,
      fontSize: 18,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(color: NoirColors.pureWhite),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: const TextStyle(color: NoirColors.textMuted),
          labelStyle: const TextStyle(color: NoirColors.textMuted),
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: NoirColors.surfaceDark2),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: NoirColors.pureWhite),
          ),
        ),
      ),
    );
  }
}
