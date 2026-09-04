import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app.dart' show routeObserver;
import '../../core/config/tv_mode.dart';
import '../../core/theme/app_colors.dart';
import '../browse/browse_screen.dart';
import '../favorites/favorites_screen.dart';
import '../home/home_screen.dart';
import '../offline/offline_screen.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import '../import/import_screen.dart';
import 'mobile_nav.dart';
import 'tv_left_rail.dart';

/// Root navigation shell that switches between mobile and TV layouts.
///
/// Mobile layout: six-tab bottom navigation bar.
/// TV layout: ten-item left vertical rail.
/// TV mode is controlled by the shared [TvMode] single source of truth
/// (the user's "TV Mode" toggle in Settings); device size heuristics are
/// no longer used here.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with RouteAware {
  int _mobileIndex = 0;
  int _tvIndex = 0;

  /// Defaults MUST match the Settings screen defaults (see settings_screen
  /// `_loadPreferences`). Using `true` here made the Radio tab flash on
  /// first boot even though the preference defaults to hidden.
  bool _showRadioTab = false;

  /// False until preferences have been read at least once. The shell must
  /// not build its tab layout with defaults while the async read is in
  /// flight — otherwise the first frame renders tabs that may not match
  /// the persisted preferences.
  bool _prefsLoaded = false;

  /// Notifier that increments every time the active tab changes.
  /// Child screens listen to this to know when to refresh their data.
  final _tabChangeNotifier = ValueNotifier<int>(0);

  /// Focus node for the TV content pane. The rail hands focus here when the
  /// user presses Right, so D-pad navigation continues in the content grid.
  final FocusNode _contentFocusNode = FocusNode(debugLabel: 'tv-content-pane');

  /// Whether the UI should use the TV layout.
  ///
  /// Read from the shared [TvMode] single source of truth, which is loaded
  /// at app startup and updated (and persisted) by the Settings toggle.
  /// Foldable devices and large tablets no longer auto-switch to TV mode.
  bool get _isTv => TvMode.instance.isEnabled;

  @override
  void initState() {
    super.initState();
    // Rebuild whenever the shared TV-mode state changes (Settings toggle).
    TvMode.instance.addListener(_onTvModeChanged);
    _loadPreferences();
  }

  /// Called when the shared [TvMode] notifier fires.
  void _onTvModeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    TvMode.instance.removeListener(_onTvModeChanged);
    _tabChangeNotifier.dispose();
    _contentFocusNode.dispose();
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  /// Called when a pushed route above this one is popped — i.e. the user
  /// returns to the shell from Settings or any other screen.
  @override
  void didPopNext() {
    _loadPreferences();
  }

  /// Loads user preferences that affect the shell layout.
  ///
  /// Called on init and when returning from settings so changes to radio
  /// tab visibility take effect immediately. TV mode itself is owned by the
  /// shared [TvMode] notifier, which the Settings toggle updates directly.
  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showRadioTab = prefs.getBool('show_radio_tab') ?? false;
      _prefsLoaded = true;

      // Keep the selected tab valid when the tab count changes. Hiding the
      // Radio tab shifts Downloads from index 5 to 4 — clamp the index so
      // the IndexedStack never points past the last child.
      final mobileTabCount = _showRadioTab ? 6 : 5;
      if (_mobileIndex >= mobileTabCount) {
        _mobileIndex = mobileTabCount - 1;
      }
    });
  }

  void _onTabChanged(int index) {
    setState(() {
      if (_isTv) {
        _tvIndex = index;
      } else {
        _mobileIndex = index;
      }
    });
    _tabChangeNotifier.value++;
  }

  // ---------------------------------------------------------------------------
  // Content builders for each tab
  // ---------------------------------------------------------------------------

  Widget _buildMobileTab(int index) {
    if (_showRadioTab) {
      // Six tabs: Home, Live TV, Movies, Series, Radio, Downloads.
      switch (index) {
        case 0: // Home
          return HomeScreen(
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 1: // Live TV
          return BrowseScreen(
            contentType: 'live',
            title: 'Live TV',
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 2: // Movies
          return BrowseScreen(
            contentType: 'vod',
            title: 'Movies',
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 3: // Series
          return BrowseScreen(
            contentType: 'series',
            title: 'Series',
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 4: // Radio
          return BrowseScreen(
            contentType: 'radio',
            title: 'Radio',
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 5: // Downloads
          return OfflineScreen(
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
            onExploreContent: () => _onTabChanged(2), // Movies tab
          );
        default:
          return HomeScreen(
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
      }
    } else {
      // Five tabs: Home, Live TV, Movies, Series, Downloads (Radio hidden).
      switch (index) {
        case 0: // Home
          return HomeScreen(
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 1: // Live TV
          return BrowseScreen(
            contentType: 'live',
            title: 'Live TV',
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 2: // Movies
          return BrowseScreen(
            contentType: 'vod',
            title: 'Movies',
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 3: // Series
          return BrowseScreen(
            contentType: 'series',
            title: 'Series',
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
        case 4: // Downloads
          return OfflineScreen(
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
            onExploreContent: () => _onTabChanged(2), // Movies tab
          );
        default:
          return HomeScreen(
            tabChangeNotifier: _tabChangeNotifier,
            tabIndex: index,
          );
      }
    }
  }

  Widget _buildTvTab(int index) {
    switch (index) {
      case 0: // Home
        return HomeScreen(
          tabChangeNotifier: _tabChangeNotifier,
          tabIndex: index,
        );
      case 1: // Series
        return BrowseScreen(
          contentType: 'series',
          title: 'Series',
          tabChangeNotifier: _tabChangeNotifier,
          tabIndex: index,
          isTv: true,
        );
      case 2: // Movies
        return BrowseScreen(
          contentType: 'vod',
          title: 'Movies',
          tabChangeNotifier: _tabChangeNotifier,
          tabIndex: index,
          isTv: true,
        );
      case 3: // Live TV
        return BrowseScreen(
          contentType: 'live',
          title: 'Live TV',
          tabChangeNotifier: _tabChangeNotifier,
          tabIndex: index,
          isTv: true,
        );
      case 4: // Radio
        return BrowseScreen(
          contentType: 'radio',
          title: 'Radio',
          tabChangeNotifier: _tabChangeNotifier,
          tabIndex: index,
          isTv: true,
        );
      case 5: // My List
        return FavoritesScreen(
          tabChangeNotifier: _tabChangeNotifier,
          tabIndex: index,
        );
      case 6: // Search
        return const SearchScreen();
      case 7: // Downloads
        return OfflineScreen(
          tabChangeNotifier: _tabChangeNotifier,
          tabIndex: index,
          onExploreContent: () => _onTabChanged(2), // Movies tab
        );
      case 8: // Settings
        return const SettingsScreen();
      case 9: // Import Playlist
        return const ImportScreen();
      default:
        return HomeScreen(
          tabChangeNotifier: _tabChangeNotifier,
          tabIndex: index,
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Don't render any tab layout until preferences are loaded, so the
    // first frame already reflects the persisted settings (e.g. Radio tab
    // hidden). Shows a brief loader during the async SharedPreferences read.
    if (!_prefsLoaded) {
      return const Scaffold(
        backgroundColor: AppColors.bgBase,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.accentPrimary),
        ),
      );
    }
    if (_isTv) {
      return _buildTvLayout();
    }
    return _buildMobileLayout();
  }

  Widget _buildMobileLayout() {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      body: IndexedStack(
        index: _mobileIndex,
        children: _showRadioTab
            ? [
                _buildMobileTab(0),
                _buildMobileTab(1),
                _buildMobileTab(2),
                _buildMobileTab(3),
                _buildMobileTab(4),
                _buildMobileTab(5),
              ]
            : [
                _buildMobileTab(0),
                _buildMobileTab(1),
                _buildMobileTab(2),
                _buildMobileTab(3),
                _buildMobileTab(4),
              ],
      ),
      bottomNavigationBar: MobileNav(
        currentIndex: _mobileIndex,
        onTap: _onTabChanged,
        showRadioTab: _showRadioTab,
      ),
    );
  }

  Widget _buildTvLayout() {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      body: Row(
        children: [
          // Rail gets its own traversal group so default traversal never
          // spills into (or comes from) the content pane.
          FocusTraversalGroup(
            child: TvLeftRail(
              currentIndex: _tvIndex,
              onTap: _onTabChanged,
              onFocusContent: () => _contentFocusNode.requestFocus(),
            ),
          ),
          // Content pane gets its own traversal group too. Requesting focus
          // on _contentFocusNode lands inside this group and the default
          // traversal moves it to the first focusable card.
          Expanded(
            child: FocusTraversalGroup(
              child: Focus(
                focusNode: _contentFocusNode,
                child: _buildTvTab(_tvIndex),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

