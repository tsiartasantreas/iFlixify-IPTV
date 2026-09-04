import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app.dart' show routeObserver;
import '../../core/config/tv_mode.dart';
import '../../core/data/database.dart';
import '../../core/data/import_progress_service.dart';
import '../../core/data/parental_control_service.dart';
import '../../core/data/supabase_client.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/animated_focus.dart';
import '../../core/widgets/favorite_button.dart';
import '../../core/widgets/pin_dialog.dart';
import '../detail/detail_screen.dart';
import '../search/search_screen.dart';

/// View mode for browse screen (persisted in SharedPreferences).
enum ViewMode { grid, list }

/// Category browse screen showing all items in a content type.
///
/// Displays a grid or list of items with optional group filtering.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({
    super.key,
    required this.contentType,
    required this.title,
    this.tabChangeNotifier,
    this.tabIndex = 0,
    this.isTv = false,
  });

  /// Content type: "live", "vod", "series", or "radio".
  final String contentType;

  /// Whether this screen is rendered inside the TV layout. Enables D-pad
  /// focus visuals (focus ring / scale) on the item cards via [AnimatedFocus].
  final bool isTv;

  /// Display title for the app bar.
  final String title;

  /// Notifier from the parent shell that fires when the active tab changes.
  final ValueNotifier<int>? tabChangeNotifier;

  /// The index of this tab in the parent shell's navigation.
  final int tabIndex;

  @override
  State<BrowseScreen> createState() => BrowseScreenState();
}

@visibleForTesting
class BrowseScreenState extends State<BrowseScreen> with RouteAware {
  final _db = AppDatabase();
  final _importProgress = ImportProgressService.instance;
  List<_BrowseItem> _allItems = [];
  List<_BrowseItem> _filteredItems = [];
  List<String> _groups = [];
  String? _selectedGroup;
  bool _isLoading = true;
  ViewMode _viewMode = ViewMode.grid;

  /// Whether parental controls are active (adult content hidden).
  bool _parentalLocked = false;

  /// Tracks the last seen tab-change notifier value so we only reload when
  /// the tab actually changes (not on the initial build).
  int _lastSeenChangeCount = 0;

  /// Map from EPG channelId to the current programme title.
  Map<String, String> _epgCurrentTitles = {};

  /// Whether this screen is rendered inside the TV layout. Reads the global
  /// [TvMode] scope, falling back to the explicit [BrowseScreen.isTv] prop.
  bool get _isTv => widget.isTv || TvModeScope.of(context);

  @override
  void initState() {
    super.initState();
    _loadViewMode();
    _loadItems();
    // Listen for background import progress changes so we can refresh
    // when a playlist import completes.
    _importProgress.progressNotifier.addListener(_onImportProgressChanged);
    // Listen for tab changes from the parent shell.
    widget.tabChangeNotifier?.addListener(_onTabChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to the global route observer so this screen refreshes its
    // data when a route pushed above the shell (e.g. Settings, Detail,
    // Player) is popped and the shell becomes visible again.
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    widget.tabChangeNotifier?.removeListener(_onTabChange);
    routeObserver.unsubscribe(this);
    _importProgress.progressNotifier.removeListener(_onImportProgressChanged);
    super.dispose();
  }

  /// Called when a pushed route above this one is popped — i.e. the user
  /// returns to the shell. Reloads items so preference changes made in
  /// Settings (e.g. parental controls) and playback side effects are
  /// reflected without a restart.
  @override
  void didPopNext() {
    _loadItems();
  }

  /// Called whenever the background import progress changes.
  void _onImportProgressChanged() {
    if (!mounted) return;
    final progress = _importProgress.progressNotifier.value;
    if (progress != null && progress.isComplete && !progress.hasError) {
      _loadItems();
    }
  }

  /// Called when the parent shell switches tabs. Reloads items if this
  /// screen just became visible (skips the initial build).
  void _onTabChange() {
    if (!mounted) return;
    final currentValue = widget.tabChangeNotifier!.value;
    if (currentValue == _lastSeenChangeCount) return;
    _lastSeenChangeCount = currentValue;
    _loadItems();
  }

  // ---------------------------------------------------------------------------
  // View mode persistence
  // ---------------------------------------------------------------------------

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('browse_view_mode');
    if (saved != null && mounted) {
      setState(() {
        _viewMode = saved == 'list' ? ViewMode.list : ViewMode.grid;
      });
    }
  }

  Future<void> _saveViewMode(ViewMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('browse_view_mode', mode == ViewMode.list ? 'list' : 'grid');
  }

  void _toggleViewMode() {
    setState(() {
      _viewMode =
          _viewMode == ViewMode.grid ? ViewMode.list : ViewMode.grid;
    });
    _saveViewMode(_viewMode);
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadItems() async {
    // ignore: avoid_print
    print('[BrowseScreen] _loadItems() called for contentType=${widget.contentType}');

    final items = <_BrowseItem>[];

    // Get playlist IDs belonging to the current user.
    final playlistIds = await _getUserPlaylistIds();
    // ignore: avoid_print
    print('[BrowseScreen] Found ${playlistIds.length} playlists for current user');

    // If the user has no playlists, return empty immediately.
    if (playlistIds.isEmpty) {
      // ignore: avoid_print
      print('[BrowseScreen] No playlists found even after fallback — '
          'showing empty state');
      if (mounted) {
        setState(() {
          _allItems = [];
          _filteredItems = [];
          _groups = [];
          _isLoading = false;
        });
      }
      return;
    }

    // Check if parental controls are active.
    final parentalLocked =
        await ParentalControlService.instance.isAdultContentLocked();

    switch (widget.contentType) {
      case 'live':
        final query = _db.select(_db.channels)
          ..where((t) => t.playlistId.isIn(playlistIds));
        final channels = await query.get();
        // ignore: avoid_print
        print('[BrowseScreen] Loaded ${channels.length} live channels');
        for (final ch in channels) {
          items.add(_BrowseItem(
            id: ch.id,
            title: ch.name,
            imageUrl: ch.logo,
            url: ch.url,
            groupTitle: ch.groupTitle,
            contentType: 'live',
            tvgName: ch.tvgName,
          ));
        }
        break;
      case 'vod':
        final query = _db.select(_db.vodItems)
          ..where((t) => t.playlistId.isIn(playlistIds));
        final vodItems = await query.get();
        // ignore: avoid_print
        print('[BrowseScreen] Loaded ${vodItems.length} VOD items');
        for (final vod in vodItems) {
          items.add(_BrowseItem(
            id: vod.id,
            title: vod.title,
            imageUrl: vod.poster,
            url: vod.url,
            groupTitle: vod.groupTitle,
            contentType: 'vod',
            rating: vod.rating,
          ));
        }
        break;
      case 'series':
        final query = _db.select(_db.tvSeries)
          ..where((t) => t.playlistId.isIn(playlistIds));
        final series = await query.get();
        // ignore: avoid_print
        print('[BrowseScreen] Loaded ${series.length} series');
        for (final s in series) {
          items.add(_BrowseItem(
            id: s.id,
            title: s.title,
            imageUrl: s.poster,
            url: '',
            groupTitle: null,
            contentType: 'series',
          ));
        }
        break;
      case 'radio':
        final query = _db.select(_db.radioStations)
          ..where((t) => t.playlistId.isIn(playlistIds));
        final stations = await query.get();
        // ignore: avoid_print
        print('[BrowseScreen] Loaded ${stations.length} radio stations');
        for (final radio in stations) {
          items.add(_BrowseItem(
            id: radio.id,
            title: radio.name,
            imageUrl: radio.logo,
            url: radio.url,
            groupTitle: null,
            contentType: 'radio',
          ));
        }
        break;
    }

    // ignore: avoid_print
    print('[BrowseScreen] Total items loaded for '
        '${widget.contentType}: ${items.length} '
        '(playlists: $playlistIds)');

    // Filter out adult content when parental controls are active.
    if (parentalLocked) {
      items.removeWhere((item) =>
          ParentalControlService.isAdultContent(
            title: item.title,
            rating: item.rating,
          ));
    }

    // Extract unique groups.
    final groupSet = <String>{};
    for (final item in items) {
      if (item.groupTitle != null && item.groupTitle!.isNotEmpty) {
        groupSet.add(item.groupTitle!);
      }
    }

    // Load EPG data for live channels.
    Map<String, String> epgTitles = {};
    if (widget.contentType == 'live') {
      epgTitles = await _loadEpgCurrentTitles();
    }

    if (mounted) {
      setState(() {
        _allItems = items;
        _filteredItems = items;
        _groups = groupSet.toList()..sort();
        _epgCurrentTitles = epgTitles;
        _parentalLocked = parentalLocked;
        _isLoading = false;
      });
    }
  }

  /// Loads a map of EPG channelId -> current programme title.
  Future<Map<String, String>> _loadEpgCurrentTitles() async {
    try {
      final now = DateTime.now();
      final programmes = await (_db.select(_db.epgProgrammes)
            ..orderBy([(t) => OrderingTerm.asc(t.channelId)]))
          .get();

      final map = <String, String>{};
      for (final p in programmes) {
        // Filter to currently airing programmes (start <= now < stop).
        if (!p.start.isAfter(now) && p.stop.isAfter(now)) {
          map[p.channelId] = p.title;
        }
      }
      return map;
    } catch (e) {
      // ignore: avoid_print
      print('[BrowseScreen] Failed to load EPG data: $e');
      return {};
    }
  }

  /// Returns the IDs of playlists belonging to the current user.
  ///
  /// If the user is signed in, filters by their Supabase user ID.
  /// If anonymous, returns playlists with no user_id set.
  ///
  /// **Fallback**: If the filtered query returns zero results, retries with
  /// ALL playlists (ignoring userId). This handles auth-state mismatches
  /// (e.g. playlist imported while authenticated but session expired, or
  /// vice versa) so content is never hidden due to stale auth context.
  Future<List<int>> _getUserPlaylistIds() async {
    try {
      await SupabaseService.initialize();
    } catch (_) {}

    String? userId;
    if (SupabaseService.isInitialized) {
      userId = SupabaseService.client.auth.currentUser?.id;
    }
    // ignore: avoid_print
    print('[BrowseScreen._getUserPlaylistIds] userId=$userId, '
        'supabaseInitialized=${SupabaseService.isInitialized}');

    List<Playlist> playlists;
    if (userId != null) {
      playlists = await (_db.select(_db.playlists)
            ..where((t) => t.userId.equals(userId!)))
          .get();
    } else {
      playlists = await (_db.select(_db.playlists)
            ..where((t) => t.userId.isNull()))
          .get();
    }

    // Fallback: if no playlists matched the user filter, try without any
    // filter. This covers cases where the auth state at query time differs
    // from the auth state at import time.
    if (playlists.isEmpty) {
      // ignore: avoid_print
      print('[BrowseScreen._getUserPlaylistIds] No playlists matched '
          'userId filter — falling back to ALL playlists');
      playlists = await (_db.select(_db.playlists)).get();
    }

    final ids = playlists.map((p) => p.id).toList();
    // ignore: avoid_print
    print('[BrowseScreen._getUserPlaylistIds] Returning ${ids.length} '
        'playlist IDs: $ids');
    return ids;
  }

  void _filterByGroup(String? group) {
    setState(() {
      _selectedGroup = group;
      _filteredItems = group == null
          ? _allItems
          : _allItems
              .where((item) => item.groupTitle == group)
              .toList();
    });
  }

  Future<void> _onRefresh() async {
    await _loadItems();
  }

  /// Returns the current EPG programme title for a live channel,
  /// matching by tvgName (EPG matching key) or channel name.
  String? _epgTitleForItem(_BrowseItem item) {
    if (item.contentType != 'live') return null;
    // Try matching by tvgName first.
    if (item.tvgName != null && item.tvgName!.isNotEmpty) {
      final title = _epgCurrentTitles[item.tvgName!];
      if (title != null) return title;
    }
    // Fallback: match by channel name.
    return _epgCurrentTitles[item.title];
  }

  // ---------------------------------------------------------------------------
  // Parental controls
  // ---------------------------------------------------------------------------

  /// Unlocks adult content for this session so it becomes visible.
  ///
  /// A PIN is only requested when one is actually configured; hiding or
  /// showing adult content is a PIN-free preference that lives in Settings.
  Future<void> _unlockAdultContent() async {
    if (await ParentalControlService.instance.isPinSet()) {
      if (!mounted) return;
      final unlocked = await showPinVerifyDialog(context);
      if (!unlocked || !mounted) return;
    }
    // Unlock adult content for the rest of this app session.
    ParentalControlService.instance.unlockTemporarily();
    if (!mounted) return;
    setState(() => _parentalLocked = false);
    await _loadItems();
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _navigateToDetail(_BrowseItem item) {
    // No `.then` reload here — returning from the detail route triggers
    // [didPopNext] via the global route observer, which reloads items.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          id: item.id,
          title: item.title,
          imageUrl: item.imageUrl,
          url: item.url,
          groupTitle: item.groupTitle,
          contentType: item.contentType,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: Text(
          widget.title,
          style: const TextStyle(color: AppColors.textPrimary),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        actions: [
          // Unlock adult content button (shown when parental controls are on).
          if (_parentalLocked)
            IconButton(
              icon: const Icon(Icons.lock_outline, color: AppColors.accentPrimary),
              onPressed: _unlockAdultContent,
              tooltip: 'Unlock adult content',
            ),
          // View toggle button.
          IconButton(
            icon: Icon(
              _viewMode == ViewMode.grid ? Icons.view_list : Icons.grid_view,
              color: AppColors.textPrimary,
            ),
            onPressed: _toggleViewMode,
            tooltip: _viewMode == ViewMode.grid
                ? 'Switch to list view'
                : 'Switch to grid view',
          ),
          IconButton(
            icon: const Icon(Icons.search, color: AppColors.textPrimary),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      SearchScreen(contentType: widget.contentType),
                ),
              );
            },
            tooltip: 'Search',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: AppColors.accentPrimary,
              ),
            )
          : Column(
              children: [
                // -- Group filter chips -------------------------------------
                if (_groups.isNotEmpty) _buildGroupChips(),

                // -- Item count ---------------------------------------------
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_filteredItems.length} items',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),

                // -- Content (grid or list) ---------------------------------
                Expanded(
                  child: _filteredItems.isEmpty
                      ? const Center(
                          child: Text(
                            'No items in this category.',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 16,
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          color: AppColors.accentPrimary,
                          backgroundColor: AppColors.bgElevated,
                          onRefresh: _onRefresh,
                          child: _viewMode == ViewMode.grid
                              ? _buildGridView()
                              : _buildListView(),
                        ),
                ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // Grid view
  // ---------------------------------------------------------------------------

  Widget _buildGridView() {
    return FocusTraversalGroup(
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.55,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: _filteredItems.length,
        itemBuilder: (context, index) {
          return _buildItemCard(
            _filteredItems[index],
            autofocus: index == 0,
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // List view
  // ---------------------------------------------------------------------------

  Widget _buildListView() {
    return FocusTraversalGroup(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: _filteredItems.length,
        itemBuilder: (context, index) {
          return _buildListItem(
            _filteredItems[index],
            autofocus: index == 0,
          );
        },
      ),
    );
  }

  Widget _buildListItem(_BrowseItem item, {bool autofocus = false}) {
    final epgTitle = _epgTitleForItem(item);

    final card = Focus(
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA) {
            _navigateToDetail(item);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () => _navigateToDetail(item),
        child: Card(
          color: AppColors.bgElevated,
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // -- Thumbnail ----------------------------------------------
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppColors.bgSurface,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: item.imageUrl != null && item.imageUrl!.isNotEmpty
                      ? Image.network(
                          item.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _buildSmallPlaceholder(),
                        )
                      : _buildSmallPlaceholder(),
                ),
                const SizedBox(width: 12),

                // -- Title, category, EPG -----------------------------------
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (item.groupTitle != null &&
                          item.groupTitle!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            item.groupTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (epgTitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            epgTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.accentPrimary.withValues(alpha: 0.8),
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // -- Favourite button --------------------------------------
                FavoriteButton(
                  contentId: '${item.contentType}:${item.id}',
                  contentType: item.contentType,
                  title: item.title,
                  poster: item.imageUrl,
                  url: item.url,
                  size: 22,
                ),
                const SizedBox(width: 4),

                // -- Play button --------------------------------------------
                IconButton(
                  icon: const Icon(
                    Icons.play_circle_outline,
                    color: AppColors.accentPrimary,
                    size: 32,
                  ),
                  onPressed: () => _navigateToDetail(item),
                  tooltip: 'Play ${item.title}',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (_isTv) {
      return AnimatedFocus(isTv: true, child: card);
    }
    return card;
  }

  // ---------------------------------------------------------------------------
  // Group chips
  // ---------------------------------------------------------------------------

  Widget _buildGroupChips() {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _buildChip('All', null),
          for (final group in _groups) _buildChip(group, group),
        ],
      ),
    );
  }

  Widget _buildChip(String label, String? group) {
    final isSelected = _selectedGroup == group;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.gameButtonA) {
              _filterByGroup(group);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: FilterChip(
          label: Text(label),
          selected: isSelected,
          onSelected: (_) => _filterByGroup(group),
          selectedColor: AppColors.accentPrimary,
          backgroundColor: AppColors.bgSurface,
          labelStyle: TextStyle(
            color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
          checkmarkColor: AppColors.textPrimary,
          side: BorderSide.none,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Grid item card
  // ---------------------------------------------------------------------------

  Widget _buildItemCard(_BrowseItem item, {bool autofocus = false}) {
    final epgTitle = _epgTitleForItem(item);

    final card = Focus(
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA) {
            _navigateToDetail(item);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () => _navigateToDetail(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // -- Poster / thumbnail with favourite button ------------------
            Expanded(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.bgSurface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: item.imageUrl != null && item.imageUrl!.isNotEmpty
                        ? Image.network(
                            item.imageUrl!,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            errorBuilder: (context, error, stackTrace) =>
                                _buildPlaceholder(),
                          )
                        : _buildPlaceholder(),
                  ),
                  // -- Favourite heart (top-right) -------------------------
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: AppColors.bgBase.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: FavoriteButton(
                        contentId: '${item.contentType}:${item.id}',
                        contentType: item.contentType,
                        title: item.title,
                        poster: item.imageUrl,
                        url: item.url,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // -- Title -----------------------------------------------------
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),

            // -- Group tag --------------------------------------------------
            if (item.groupTitle != null && item.groupTitle!.isNotEmpty)
              Text(
                item.groupTitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),

            // -- EPG current programme ------------------------------------
            if (epgTitle != null)
              Text(
                epgTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.accentPrimary.withValues(alpha: 0.8),
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      ),
    );

    if (_isTv) {
      return AnimatedFocus(isTv: true, child: card);
    }
    return card;
  }

  Widget _buildPlaceholder() {
    return const Center(
      child: Icon(
        Icons.movie,
        color: AppColors.bgSurface,
        size: 40,
      ),
    );
  }

  Widget _buildSmallPlaceholder() {
    return const Center(
      child: Icon(
        Icons.movie,
        color: AppColors.textSecondary,
        size: 24,
      ),
    );
  }
}

/// Internal model for browse items.
class _BrowseItem {
  const _BrowseItem({
    required this.id,
    required this.title,
    this.imageUrl,
    required this.url,
    this.groupTitle,
    required this.contentType,
    this.tvgName,
    this.rating,
  });

  final int id;
  final String title;
  final String? imageUrl;
  final String url;
  final String? groupTitle;
  final String contentType;

  /// M3U `tvg-name` — used to match EPG data to live channels.
  final String? tvgName;

  /// Content rating (e.g. "18+", "R18").
  final String? rating;
}
