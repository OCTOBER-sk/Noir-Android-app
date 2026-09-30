// lib/main.dart — the app's entry point, and the only place the object graph is
// built.
//
// What changed here and why. This file used to construct two objects
// (`ConversationController` and `UsageTracker`) and hand them to a splash
// screen. The other 46 files under lib/ — the entire data layer, the memory
// service, the prompt service, the MCP composition, the provider runtime, the
// agent runtime — were implemented, unit-tested, and not used by the shipped
// app at all. Neither `flutter analyze` nor `flutter test` could see that,
// because the test files import those modules directly, so a module's being
// "covered" and its being "shipped" were indistinguishable. Nothing here
// fabricates a value to compensate: what the app can build, it builds, and what
// it cannot build is a typed state the UI renders as the problem it is.
//
// Startup order, and why:
//
//   1. Safety before anything that could act. The PolicyEngine is constructed
//      first and handed to the NativeBridge, so the gate the platform calls back
//      into and the gate the pipeline uses are the same object.
//   2. Persistence is probed, not assumed. `NoirComposition.open` verifies a
//      writable directory before writing anything. This build has no
//      `path_provider`, so on a platform with no app-writable directory there
//      genuinely is nowhere to put a record, and the app says so on screen
//      rather than writing somewhere the user was not told about.
//   3. The provider runtime comes from the user's own settings. There is no
//      default endpoint and no default key, so with nothing configured the
//      assistant reports that it has no backend instead of inventing a reply.
//   4. The model catalog is fetched after the first frame. A `/models` read is
//      a network call to a provider the user configured; blocking the first
//      frame on it would make the app look broken on a slow connection. Until it
//      resolves, the catalog is in an explicit state and no model is claimed.
//
// The pre-existing entry path is unchanged: a `ConversationController`, a
// `CommandCentreScreen` and a `UsageTracker` are still what the app runs, and
// they are the very same instances the rest of the graph writes to.
//
// What `_NoirAppState` owns, and it is not a startup step: the foreground tick
// that dispatches scheduled automations. A scheduled job could be created, was
// durable, was listed in the Skill Manager — and nothing ever asked what was
// due, because the only caller of the graph's dispatch was a test. So the app
// arms the tick when it mounts and disarms it whenever the lifecycle says the
// app is no longer in front, which is the strongest promise this build can
// make: there is no `AlarmManager`, no `WorkManager` and no background service
// here, so a job whose time came while the app was closed runs when the app next
// opens, and never while the process is dead. Every job it offers still goes
// through the same policy gate and the same confirmation a tap needs, because
// the tick's one seam is the graph's own `runDueAutomations`.
//
// What the splash now says as well: whether the graph may be called ready.
// `NoirComposition.open` records every step it took, and the readiness line is
// computed from that record rather than asserted beside it — so a startup whose
// persistence failed says "not ready" and names the subsystem, instead of
// printing a reassuring line over a graph that cannot keep a conversation.
import 'dart:async';

import 'package:flutter/material.dart';

import 'core/composition_root.dart';
import 'core/conversation_controller.dart';
import 'providers/usage_tracker.dart';
import 'ui/command_centre_screen.dart';
import 'ui/operations_sheet.dart';
import 'ui/settings_screen.dart';
import 'core/theme/noir_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Every real system is built before the first frame; the only thing that waits
  // is the network read described above.
  unawaited(runNoir());
}

/// Builds the graph and runs the app on it.
///
/// Deterministic by construction: [NoirComposition.open] awaits persistence,
/// memory, prompts, usage, the provider runtime, the safety stack, MCP, the
/// conversation and the transcript restore in that fixed order, and the app is
/// only handed to `runApp` once every one of them has either succeeded or become
/// a typed state. Nothing is retried behind the user's back and nothing is
/// skipped, so two launches over the same directory build the same graph.
Future<void> runNoir() async {
  final NoirComposition composition = await NoirComposition.open();
  runApp(NoirApp(composition: composition));
}

/// The application widget. Holds the graph and injects it into the UI.
class NoirApp extends StatefulWidget {
  const NoirApp({super.key, required this.composition});

  /// The graph built at startup. Owned here, disposed with the app.
  final NoirComposition composition;

  @override
  State<NoirApp> createState() => _NoirAppState();
}

class _NoirAppState extends State<NoirApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // After the first frame, not before: this is the network read, and the
    // first frame must not wait on it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(widget.composition.warmUp());
    });
    // The tick that dispatches due automations lives for as long as the app is
    // in front of the user, and this is the only place that knows when that is.
    // Mounting the app *is* the app coming up, so the tick is armed here; the
    // observer below disarms it on the way out and re-arms it on the way back.
    // That is the whole of the promise, because this build has no platform alarm
    // and no background service: a job is offered while the app is up, and when
    // the app comes up again after being closed.
    WidgetsBinding.instance.addObserver(this);
    widget.composition.startAutomationScheduler();
    widget.composition.addListener(_onCompositionChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        widget.composition.startAutomationScheduler();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        widget.composition.stopAutomationScheduler();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The tick is stopped with the app, and again by the graph's own disposal
    // below. Neither is a race: a stopped scheduler ignores a held callback.
    widget.composition.stopAutomationScheduler();
    widget.composition.removeListener(_onCompositionChanged);
    unawaited(widget.composition.dispose());
    super.dispose();
  }

  void _onCompositionChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final NoirComposition composition = widget.composition;
    return MaterialApp(
      title: 'Noir',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: NoirColors.nearBlack,
        scaffoldBackgroundColor: NoirColors.pureBlack,
        fontFamily: 'Roboto',
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: NoirColors.textSecondary),
          bodyMedium: TextStyle(color: NoirColors.textSecondary),
        ),
      ),
      home: SplashScreen(composition: composition),
    );
  }
}

/// The startup screen. Reports what the graph actually built.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.composition});

  final NoirComposition composition;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  /// Enough time to read the logo, not enough to hide a failure. A build that
  /// could not open its store says so here rather than after a fake delay.
  static const Duration _minimumVisible = Duration(milliseconds: 1600);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_minimumVisible, () {
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute<void>(builder: (_) => _buildApp()));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// The Command Centre with the real graph injected.
  ///
  /// [ConversationController], [CommandCentreScreen] and [UsageTracker] stay
  /// exactly where they were: the same classes, fed by the same instances the
  /// rest of the app writes to. What is new is everything the composition root
  /// brought with it.
  Widget _buildApp() {
    final NoirComposition composition = widget.composition;
    // One function, two screens. The Command Centre's confirmation card and the
    // Operations sheet's prompt are the same question asked of the same gate, so
    // they must reach `PendingConfirmation.answer` through one implementation —
    // two copies of this lambda would eventually disagree about what consenting
    // means, and one of them would be the copy nobody re-reads.
    void answerConfirmation(PendingConfirmation confirmation, bool approved) {
      // The gate holds the pending request; answering it here is the whole
      // consent path, and the only call that can approve a gated action.
      confirmation.answer(approved);
    }

    return CommandCentreScreen(
      controller: composition.conversation,
      usage: composition.usage,
      bridge: composition.bridge,
      mcp: composition.mcp,
      replyStream: composition.assistantReplies,
      // The real event bus. Without this the Command Centre's streaming rows,
      // confirmation card, undo toast and skeleton loader were unreachable: the
      // screen had the renderer but no source, so the graph could emit real
      // events and the screen still showed none of them.
      events: composition.taskRun.events,
      // The policy gate's own request stream and the answer that releases it.
      // The card the user is already looking at when a gated run starts used to
      // print two dead buttons and claim no gate was wired, so the only route to
      // consent was to leave this screen and find the Operations sheet.
      confirmations: composition.confirmations,
      onAnswerConfirmation: answerConfirmation,
      // The D15 Undo control's executor, and the same rule as the answer above:
      // the toast may only be live when something real is behind it. This is the
      // graph's own `undo`, so a press ends the live window and runs the
      // compensation through the same gate and the same confirmation a tap needs.
      onUndoAction: composition.undo,
      operations: OperationsSheet(
        bridge: composition.bridge,
        taskTimeline: composition.taskTimeline(),
        usage: composition.usageStates(),
        skills: composition.skills(),
        confirmations: composition.confirmations,
        onAnswerConfirmation: answerConfirmation,
        onRun: (AutomationRequest request) async {
          await composition.runAutomation(request);
        },
      ),
      // The safety log the Safety Center renders. Without it the screen said "No
      // safety log is connected." while the graph was recording every blocked
      // gesture, every sanitized dump and every A4 recovery into exactly this
      // stream — the decisions existed and were unreachable.
      safetyEvents: composition.safetyEvents(),
      onOpenSettings: _openSettings,
    );
  }

  /// Opens the settings screen over the real settings repository.
  ///
  /// The graph wires its provider runtime once, at startup, so a key saved here
  /// takes effect on the next launch rather than instantly. The screen says so
  /// after a save instead of implying the running graph picked it up.
  Future<void> _openSettings() async {
    final NoirComposition composition = widget.composition;
    final DataWiring data = composition.data;
    if (data is! DataOpened) {
      // No writable store means nowhere to keep a key. Said plainly rather than
      // opening a form that could not save anything.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Noir has no writable store on this device, so a provider key '
            'cannot be saved.',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(settings: data.layer.settings),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final NoirComposition composition = widget.composition;
    final StartupState startup = composition.startup;
    return Scaffold(
      backgroundColor: NoirColors.pureBlack,
      body: Center(
        // Scrollable, because the honest answer is sometimes longer than the
        // happy one: a startup with several faults to report must not overflow
        // and hide the reasons it is reporting.
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Image.asset(
                'assets/noir_logo.png',
                width: 200,
                height: 200,
                filterQuality: FilterQuality.high,
              ),
              const SizedBox(height: 24),
              const Text(
                'Noir',
                style: TextStyle(
                  color: NoirColors.textSecondary,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'On-device automation',
                style: TextStyle(
                  color: NoirColors.textMuted,
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 40),
              // Whether the graph may be called ready, and exactly which subsystem
              // says no. Rebuilt when the graph learns something new — a catalog
              // that could not be read, for instance, arrives after this screen is
              // already up.
              Text(
                _readinessLine(startup),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: startup.isReady
                      ? NoirColors.textSecondary
                      : NoirColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              // The one thing worth saying before the app opens: whether this
              // build has somewhere to keep what the user gives it.
              Text(
                _startupLine(composition),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: NoirColors.textMuted,
                  fontSize: 11,
                  letterSpacing: 0.2,
                  height: 1.5,
                ),
              ),
              // One line per fault, so "not ready" is never a bare verdict the user
              // has to take on trust.
              for (final StartupFault fault in startup.faults)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 32, right: 32),
                  child: Text(
                    '${fault.subsystem}: ${fault.reason}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: NoirColors.textMuted,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether the app may claim to be ready.
  ///
  /// Never a bare "ready": with a required subsystem down the line says so, and
  /// the faults below it name the subsystem and the reason.
  static String _readinessLine(StartupState startup) {
    if (startup is StartupFailed) {
      return startup.faults.any(
            (StartupFault fault) =>
                fault.subsystem == kRequiredStartupSubsystem,
          )
          ? 'NOT READY — NO RECORD STORE'
          : 'NOT READY';
    }
    if (startup is StartupDegraded) {
      return 'READY — ${startup.faults.length} SUBSYSTEM(S) UNAVAILABLE';
    }
    return 'READY';
  }

  /// What the graph managed to build, in one line, or in three when the honest
  /// answer is a problem.
  static String _startupLine(NoirComposition composition) {
    final DataWiring data = composition.data;
    if (data is DataUnavailable) {
      return 'No durable storage: ${data.reason}\n'
          'Noir will not save anything this session.';
    }
    final DataOpened opened = data as DataOpened;
    final String where = opened.root.path;
    final String persistence = opened.layer.store.isDurable
        ? 'Records are durable'
        : 'Records are held for this session only';
    return '$persistence in $where';
  }
}
