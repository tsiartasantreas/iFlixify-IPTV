import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'core/auth/profile_manager.dart';
import 'core/entitlement/entitlement_service.dart';
import 'core/purchase/purchase_service.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/netflix_theme.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/main_shell.dart';

/// Global route observer used by [MainShell] to detect when it becomes
/// visible again after a pushed route (e.g. Settings) is popped.
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

/// Root widget of the iFlixify IPTV app.
///
/// Supabase is NEVER initialized at startup — its native Android plugin
/// (app_links via supabase_flutter) crashes on Android 16. Initialize
/// lazily only when the user explicitly signs in. The app works fully
/// in guest mode without any network dependency.
class FlixiumApp extends StatefulWidget {
  const FlixiumApp({super.key});

  @override
  State<FlixiumApp> createState() => _FlixiumAppState();
}

class _FlixiumAppState extends State<FlixiumApp> {
  bool _initialized = false;
  bool _showOnboarding = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Ensure a default profile exists for first-time users.
    try {
      await ProfileManager.instance.ensureDefaultProfile();
    } catch (_) {}

    // Pull profiles from Supabase if the user is authenticated.
    try {
      await ProfileManager.instance.syncFromCloud();
    } catch (_) {}

    // Check if this is the first launch
    _showOnboarding = !await OnboardingScreen.hasCompleted();

    // Initialize Google Play Billing (non-blocking, best-effort).
    try {
      final purchaseService =
          PurchaseService(entitlementService: EntitlementService());
      await purchaseService.initialize();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _initialized = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: NetflixTheme.dark,
        home: const Scaffold(
          backgroundColor: AppColors.bgBase,
          body: Center(
            child: CircularProgressIndicator(color: AppColors.accentPrimary),
          ),
        ),
      );
    }

    return SentryWidget(
      child: MaterialApp(
        title: 'iFlixify IPTV',
        debugShowCheckedModeBanner: false,
        theme: NetflixTheme.dark,
        navigatorObservers: [routeObserver, SentryNavigatorObserver()],
        home: _showOnboarding
            ? OnboardingScreen(
                onComplete: () {
                  setState(() => _showOnboarding = false);
                },
              )
            : const MainShell(),
      ),
    );
  }
}
