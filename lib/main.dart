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
import 'dart:async';

import 'package:flutter/material.dart';

import 'core/composition_root.dart';
import 'core/conversation_controller.dart';
import 'providers/usage_tracker.dart';
import 'ui/command_centre_screen.dart';
import 'ui/operations_sheet.dart';
import 'core/theme/noir_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Every real system is built before the first frame; the only thing that waits
  // is the network read described above.
  unawaited(runNoir());
}

/// Builds the graph and runs the app on it.
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

class _NoirAppState extends State<NoirApp> {
  @override
  void initState() {
    super.initState();
    // After the first frame, not before: this is the network read, and the
    // first frame must not wait on it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(widget.composition.warmUp());
    });
    widget.composition.addListener(_onCompositionChanged);
  }

  @override
  void dispose() {
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
    return CommandCentreScreen(
      controller: composition.conversation,
      usage: composition.usage,
      bridge: composition.bridge,
      mcp: composition.mcp,
      replyStream: composition.assistantReplies,
      operations: OperationsSheet(
        bridge: composition.bridge,
        taskTimeline: composition.taskTimeline(),
        usage: composition.usageStates(),
        skills: composition.skills(),
        confirmations: composition.confirmations,
        onAnswerConfirmation:
            (PendingConfirmation confirmation, bool approved) {
              // The gate holds the pending request and the sheet is its only
              // holder; answering it here is the whole consent path.
              confirmation.answer(approved);
            },
        onRun: (AutomationRequest request) async {
          await composition.runAutomation(request);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final NoirComposition composition = widget.composition;
    return Scaffold(
      backgroundColor: NoirColors.pureBlack,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
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
          ],
        ),
      ),
    );
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
