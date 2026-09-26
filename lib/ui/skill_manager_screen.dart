// lib/ui/skill_manager_screen.dart — D7 (V2.3 §2.3)
//
// The list is whatever the app injects. This screen used to carry its own three
// skills (Message Triage, Form Fill, Photo Note) and a "last used 2h ago" line
// that no clock ever produced: a registry of skills that always contains the
// same three entries, all of them recently used, is a mock wearing a
// production look. Now a [SkillRecord] says who ran it and when, and a record
// that has never run says that.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/noir_theme.dart';

/// Lifecycle of one automation skill, as the registry reports it.
enum SkillState {
  /// The registry has not classified this skill.
  unknown,
  active,
  validated,

  /// A human has to look at this one before it is trusted.
  needsReview,
  disabled,
}

/// Human wording for [SkillState]. Never a bare enum name.
String skillStateLabel(SkillState state) {
  switch (state) {
    case SkillState.unknown:
      return 'unknown';
    case SkillState.active:
      return 'active';
    case SkillState.validated:
      return 'validated';
    case SkillState.needsReview:
      return 'needs review';
    case SkillState.disabled:
      return 'disabled';
  }
}

/// One registered skill. [lastUsedAt] is null when the registry has no run for
/// it, and [detail] carries whatever the registry had to say about it.
@immutable
class SkillRecord {
  const SkillRecord({
    required this.id,
    required this.name,
    this.state = SkillState.unknown,
    this.lastUsedAt,
    this.detail,
  });

  final String id;
  final String name;
  final SkillState state;
  final DateTime? lastUsedAt;
  final String? detail;

  bool get needsReview => state == SkillState.needsReview;
}

sealed class SkillListState {
  const SkillListState();
}

final class SkillListLoading extends SkillListState {
  const SkillListLoading();
}

final class SkillListFailed extends SkillListState {
  const SkillListFailed(this.message);

  final String message;
}

final class SkillListAvailable extends SkillListState {
  const SkillListAvailable(this.records);

  final List<SkillRecord> records;
}

class SkillManagerScreen extends StatefulWidget {
  const SkillManagerScreen({super.key, this.source, this.onRetry, this.now});

  /// The real skill registry. Null means nothing is wired, and the screen says
  /// so rather than listing skills that do not exist.
  final Stream<SkillListState>? source;

  /// Handler for the failure state's retry control, or null for no control.
  final VoidCallback? onRetry;

  /// Clock used to age [SkillRecord.lastUsedAt]. Injectable so the wording can
  /// be asserted without depending on when the suite runs.
  final DateTime Function()? now;

  @override
  State<SkillManagerScreen> createState() => _SkillManagerScreenState();
}

class _SkillManagerScreenState extends State<SkillManagerScreen> {
  StreamSubscription<SkillListState>? _subscription;
  SkillListState? _state;

  @override
  void initState() {
    super.initState();
    _bind(widget.source);
  }

  @override
  void didUpdateWidget(SkillManagerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.source, widget.source)) {
      return;
    }
    _unbind();
    _bind(widget.source);
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  void _bind(Stream<SkillListState>? source) {
    if (source == null) {
      return;
    }
    _state = const SkillListLoading();
    _subscription = source.listen(
      (SkillListState state) {
        if (mounted) setState(() => _state = state);
      },
      onError: (Object error) {
        if (mounted) setState(() => _state = SkillListFailed('$error'));
      },
    );
  }

  void _unbind() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    _state = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'NOIr',
                    style: TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 5,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'SKILLS',
                      style: TextStyle(
                        color: Color(0xFF888888),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(color: Color(0xFF1A1A1A), thickness: 1, height: 1),
              const SizedBox(height: 20),
              const Text(
                'Skill Manager',
                style: TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 24,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Registered automation skills',
                style: TextStyle(
                  color: Color(0xFF888888),
                  fontSize: 13,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final state = _state;
    if (state == null) {
      return const _RegistryNotice(
        title: 'No skill source is connected.',
        detail:
            'No skills are listed because no registry is wired to this '
            'screen.',
      );
    }
    if (state is SkillListLoading) {
      return const _RegistryNotice(
        title: 'Reading registered skills…',
        detail: 'Waiting for the registry to answer.',
        busy: true,
      );
    }
    if (state is SkillListFailed) {
      return _RegistryNotice(
        title: state.message,
        detail: 'The registry could not be read, so no skill is listed.',
        retry: widget.onRetry,
      );
    }
    final records = (state as SkillListAvailable).records;
    if (records.isEmpty) {
      return const _RegistryNotice(
        title: 'No skills are registered.',
        detail: 'The registry answered and it holds nothing yet.',
      );
    }
    final now = widget.now?.call() ?? DateTime.now();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: records.length,
      itemBuilder: (context, index) =>
          _SkillRow(record: records[index], now: now),
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({required this.record, required this.now});

  final SkillRecord record;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final needsReview = record.needsReview;
    final detail = record.detail;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: needsReview
              ? const Color(0xFF2A2A2A)
              : const Color(0xFF151515),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (needsReview)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 6),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: NoirColors.rainbowAccent,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            )
          else
            const SizedBox(width: 8),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFFFFFFF),
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                      skillStateLabel(record.state),
                      style: TextStyle(
                        color: needsReview
                            ? const Color(0xFFE5E5E5)
                            : const Color(0xFF888888),
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    Text(
                      _lastUsedLabel(record.lastUsedAt, now),
                      style: const TextStyle(
                        color: Color(0xFF666666),
                        fontSize: 11,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
                if (detail != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RegistryNotice extends StatelessWidget {
  const _RegistryNotice({
    required this.title,
    required this.detail,
    this.busy = false,
    this.retry,
  });

  final String title;
  final String detail;
  final bool busy;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    final onRetry = retry;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFE5E5E5),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFF5A5A5A),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: const TextStyle(
              color: Color(0xFF888888),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            _RetryButton(label: 'Retry', onPressed: onRetry),
          ],
        ],
      ),
    );
  }
}

/// A control that is only drawn when it has a real handler behind it.
class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFFB0B0B0),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wording derived from the record's own timestamp, never from a constant.
String _lastUsedLabel(DateTime? lastUsedAt, DateTime now) {
  if (lastUsedAt == null) {
    return 'never run';
  }
  final elapsed = now.difference(lastUsedAt);
  if (elapsed.isNegative || elapsed.inMinutes < 1) {
    return 'last used <1m ago';
  }
  if (elapsed.inHours < 1) {
    return 'last used ${elapsed.inMinutes}m ago';
  }
  if (elapsed.inDays < 1) {
    return 'last used ${elapsed.inHours}h ago';
  }
  return 'last used ${elapsed.inDays}d ago';
}
