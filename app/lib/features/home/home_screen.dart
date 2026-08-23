import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';

import '../../core/auth/profile_manager.dart';
import '../../core/data/database.dart';
import '../../core/data/favorites_service.dart';
import '../../core/data/import_progress_service.dart';
import '../../core/data/parental_control_service.dart';
import '../../core/data/supabase_client.dart';
import '../../core/data/watch_progress_service.dart';
import '../../core/entitlement/entitlement_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/pin_dialog.dart';
import '../browse/browse_screen.dart';
import '../detail/detail_screen.dart';
import '../favorites/favorites_screen.dart';
import '../import/import_screen.dart';
import '../profiles/profile_switcher_screen.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import 'widgets/content_row.dart';
import 'widgets/continue_watching_row.dart';

/// Main home screen displaying content organized by type.
///
/// Shows horizontal scrollable rows: Movies, Series, Live TV, Radio,
/// and a "Recently Added" cross-type row.
/// Displays an empty state with an import button if no playlists exist.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.tabChangeNotifier,
    this.tabIndex = 0,
  });

  /// Notifier from the parent shell that fires when the active tab changes.
  final ValueNotifier<int>? tabChangeNotifier;

  /// The index of this tab in the parent shell's navigation.
  final int tabIndex;

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

@visibleForTesting
class HomeScreenState extends State<HomeScreen> {
  final _db = AppDatabase();
  final _favoritesService = FavoritesService();
  // Share the screen's database instance so watch-progress lookups don't
  // open a new SQLite connection on every call.
  late final _watchProgressService = WatchProgressService(database: _db);
  final _entitlementService = EntitlementService();
  final _importProgress = ImportProgressService.instance;
  List<ContentRow> _rows = [];
  List<ContinueWatchingItem> _continueWatchingItems = [];
  List<Favorite> _favorites = [];
  List<ContentItem> _recommendedItems = [];
  bool _isEmpty = true;
  bool _isLoading = true;
  bool _parentalLocked = false;
  String _activeProfileInitials = 'U';

  /// Tracks the last seen tab-change notifier value so we only reload when
  /// the tab actually changes (not on the initial build).
  int _lastSeenChangeCount = 0;

  /// Whether the entitlement tier has been fetched at least once.
  ///
  /// [EntitlementService.isPro] is a synchronous getter over a cached tier
  /// that starts as `'free'`; without an explicit refresh the Continue
  /// Watching row would never load even for Pro users.
  bool _tierRefreshed = false;
  bool get _isTv =>
      Platform.isLinux ||
      (Platform.isAndroid &&
          MediaQueryData.fromView(
                      WidgetsBinding.instance.platformDispatcher.views.first)
                  .size
                  .shortestSide >
              600);

  @override
  void initState() {
    super.initState();
    _loadContent();
    // Listen for background import progress changes.
    _importProgress.progressNotifier.addListener(_onImportProgressChanged);
    // Listen for tab changes from the parent shell.
    widget.tabChangeNotifier?.addListener(_onTabChange);
  }

  @override
  void dispose() {
    widget.tabChangeNotifier?.removeListener(_onTabChange);
    _importProgress.progressNotifier.removeListener(_onImportProgressChanged);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // No-op: content is loaded in initState and explicitly after navigation.
  }

  /// Called whenever the background import progress changes.
  void _onImportProgressChanged() {
    if (!mounted) return;
    // Trigger a rebuild to update the progress banner.
    setState(() {});

    // When import completes, refresh the content rows.
    final progress = _importProgress.progressNotifier.value;
    if (progress != null && progress.isComplete && !progress.hasError) {
      _loadContent();
    }
  }

  /// Called when the parent shell switches tabs. Reloads content if this
  /// screen just became visible (skips the initial build).
  void _onTabChange() {
    if (!mounted) return;
    final currentValue = widget.tabChangeNotifier!.value;
    if (currentValue == _lastSeenChangeCount) return;
    _lastSeenChangeCount = currentValue;
    _loadContent();
  }

  /// Dismisses the completed import banner.
  void _dismissImportBanner() {
    _importProgress.clear();
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadActiveProfileInitials() async {
    try {
      final profileManager = ProfileManager();
      final active = await profileManager.getActiveProfile();
      if (active != null && mounted) {
        final name = active.displayName.trim();
        final initials = name.isNotEmpty
            ? name.split(RegExp(r'\s+')).map((w) => w[0]).take(2).join().toUpperCase()
            : 'U';
        setState(() => _activeProfileInitials = initials);
      }
    } catch (_) {}
  }

  Future<void> _loadFavorites() async {
    try {
      final favs = await _favoritesService.getFavorites();
      if (mounted) setState(() => _favorites = favs);
    } catch (_) {}
  }

  Future<void> _loadContent() async {
    // Load active profile initials for the AppBar avatar.
    _loadActiveProfileInitials();

    // Load favorites in parallel.
    _loadFavorites();

    // Check if parental controls are active.
    final parentalLocked =
        await ParentalControlService.instance.isAdultContentLocked();

    // Get playlist IDs belonging to the current user.
    final playlistIds = await _getUserPlaylistIds();
    if (playlistIds.isEmpty) {
      if (mounted) {
        setState(() {
          _isEmpty = true;
          _isLoading = false;
        });
      }
      return;
    }

    // Query content tables filtered by user's playlists, ordering by id
    // descending so the latest items appear first in each row.
    final channelsQuery = _db.select(_db.channels)
      ..where((t) => t.playlistId.isIn(playlistIds))
      ..orderBy([(c) => OrderingTerm.desc(c.id)]);
    final channels = await channelsQuery.get();

    final vodQuery = _db.select(_db.vodItems)
      ..where((t) => t.playlistId.isIn(playlistIds))
      ..orderBy([(v) => OrderingTerm.desc(v.id)]);
    final vodItems = await vodQuery.get();

    final seriesQuery = _db.select(_db.tvSeries)
      ..where((t) => t.playlistId.isIn(playlistIds))
      ..orderBy([(s) => OrderingTerm.desc(s.id)]);
    final series = await seriesQuery.get();

    final radioQuery = _db.select(_db.radioStations)
      ..where((t) => t.playlistId.isIn(playlistIds))
      ..orderBy([(r) => OrderingTerm.desc(r.id)]);
    final radioStations = await radioQuery.get();

    // Filter out adult content when parental controls are active.
    final filteredChannels = parentalLocked
        ? channels
            .where((ch) =>
                !ParentalControlService.isAdultContent(title: ch.name))
            .toList()
        : channels;
    final filteredVod = parentalLocked
        ? vodItems
            .where((vod) =>
                !ParentalControlService.isAdultContent(
                    title: vod.title, rating: vod.rating))
            .toList()
        : vodItems;
    final filteredSeries = parentalLocked
        ? series
            .where((s) =>
                !ParentalControlService.isAdultContent(title: s.title))
            .toList()
        : series;

    // ignore: avoid_print
    print('[HomeScreen._loadContent] playlistIds=$playlistIds');
    // ignore: avoid_print
    print('[HomeScreen._loadContent] channels=${filteredChannels.length}, '
        'vodItems=${filteredVod.length}, series=${filteredSeries.length}, '
        'radio=${radioStations.length}');

    // Load Continue Watching items (Pro only). Refresh the cached tier once
    // so `isPro` reflects the actual account instead of the default 'free'.
    final continueWatchingItems = <ContinueWatchingItem>[];
    if (!_tierRefreshed) {
      await _entitlementService.refreshTier();
      _tierRefreshed = true;
    }
    if (_entitlementService.isPro) {
      final progressEntries =
          await _watchProgressService.getContinueWatching(limit: 10);
      for (final entry in progressEntries) {
        final item = await _resolveContentItem(entry.contentId);
        if (item != null) continueWatchingItems.add(item);
      }
    }

    // Build the "Recommended For You" row from watch history + favourites.
    // Uses the parentally filtered lists so recommendations respect the
    // same restrictions as the other rows.
    final recommendedItems = await _buildRecommendedItems(
      vodItems: filteredVod,
      seriesItems: filteredSeries,
      channels: filteredChannels,
    );

    if (mounted) {
      final rows = <ContentRow>[];
      bool isFirstRow = true;

      // -- Movies row --------------------------------------------------------
      if (filteredVod.isNotEmpty) {
        rows.add(ContentRow(
          label: 'Movies',
          isTv: _isTv,
          autofocusFirst: _isTv && isFirstRow,
          items: filteredVod.take(20).map((vod) {
            return ContentItem(
              title: vod.title,
              imageUrl: vod.poster,
              contentId: 'vod:${vod.id}',
              contentType: 'vod',
              url: vod.url,
              onTap: () => _navigateToDetail(
                id: vod.id,
                title: vod.title,
                imageUrl: vod.poster,
                url: vod.url,
                groupTitle: vod.groupTitle,
                contentType: 'vod',
              ),
            );
          }).toList(),
          onSeeAll: () => _navigateToBrowse('vod', 'Movies'),
        ));
        isFirstRow = false;
      }

      // -- Series row --------------------------------------------------------
      if (filteredSeries.isNotEmpty) {
        rows.add(ContentRow(
          label: 'Series',
          isTv: _isTv,
          autofocusFirst: _isTv && isFirstRow,
          items: filteredSeries.take(20).map((s) {
            return ContentItem(
              title: s.title,
              imageUrl: s.poster,
              contentId: 'series:${s.id}',
              contentType: 'series',
              onTap: () => _navigateToDetail(
                id: s.id,
                title: s.title,
                imageUrl: s.poster,
                url: '',
                contentType: 'series',
              ),
            );
          }).toList(),
          onSeeAll: () => _navigateToBrowse('series', 'Series'),
        ));
        isFirstRow = false;
      }

      // -- Live TV row -------------------------------------------------------
      if (filteredChannels.isNotEmpty) {
        rows.add(ContentRow(
          label: 'Live TV',
          isTv: _isTv,
          autofocusFirst: _isTv && isFirstRow,
          items: filteredChannels.take(20).map((ch) {
            return ContentItem(
              title: ch.name,
              imageUrl: ch.logo,
              contentId: 'channel:${ch.id}',
              contentType: 'live',
              url: ch.url,
              onTap: () => _navigateToDetail(
                id: ch.id,
                title: ch.name,
                imageUrl: ch.logo,
                url: ch.url,
                groupTitle: ch.groupTitle,
                contentType: 'live',
              ),
            );
          }).toList(),
          onSeeAll: () => _navigateToBrowse('live', 'Live TV'),
        ));
        isFirstRow = false;
      }

      // -- Radio row ---------------------------------------------------------
      if (radioStations.isNotEmpty) {
        rows.add(ContentRow(
          label: 'Radio',
          isTv: _isTv,
          autofocusFirst: _isTv && isFirstRow,
          items: radioStations.take(20).map((radio) {
            return ContentItem(
              title: radio.name,
              imageUrl: radio.logo,
              contentId: 'radio:${radio.id}',
              contentType: 'radio',
              url: radio.url,
              onTap: () => _navigateToDetail(
                id: radio.id,
                title: radio.name,
                imageUrl: radio.logo,
                url: radio.url,
                contentType: 'radio',
              ),
            );
          }).toList(),
          onSeeAll: () => _navigateToBrowse('radio', 'Radio'),
        ));
        isFirstRow = false;
      }

      // -- Recently Added row (newest items across all types) ----------------
      final recentItems = <_RecentItem>[];
      for (final vod in filteredVod.take(5)) {
        recentItems.add(_RecentItem(
          id: vod.id,
          title: vod.title,
          imageUrl: vod.poster,
          contentId: 'vod:${vod.id}',
          contentType: 'vod',
          url: vod.url,
          navigate: () => _navigateToDetail(
            id: vod.id,
            title: vod.title,
            imageUrl: vod.poster,
            url: vod.url,
            groupTitle: vod.groupTitle,
            contentType: 'vod',
          ),
        ));
      }
      for (final s in filteredSeries.take(5)) {
        recentItems.add(_RecentItem(
          id: s.id,
          title: s.title,
          imageUrl: s.poster,
          contentId: 'series:${s.id}',
          contentType: 'series',
          navigate: () => _navigateToDetail(
            id: s.id,
            title: s.title,
            imageUrl: s.poster,
            url: '',
            contentType: 'series',
          ),
        ));
      }
      for (final ch in filteredChannels.take(5)) {
        recentItems.add(_RecentItem(
          id: ch.id,
          title: ch.name,
          imageUrl: ch.logo,
          contentId: 'channel:${ch.id}',
          contentType: 'live',
          url: ch.url,
          navigate: () => _navigateToDetail(
            id: ch.id,
            title: ch.name,
            imageUrl: ch.logo,
            url: ch.url,
            groupTitle: ch.groupTitle,
            contentType: 'live',
          ),
        ));
      }
      // Sort by id descending so the truly newest items are first.
      recentItems.sort((a, b) => b.id.compareTo(a.id));

      if (recentItems.isNotEmpty) {
        rows.add(ContentRow(
          label: 'Recently Added',
          isTv: _isTv,
          autofocusFirst: _isTv && isFirstRow,
          items: recentItems.take(20).map((item) {
            return ContentItem(
              title: item.title,
              imageUrl: item.imageUrl,
              contentId: item.contentId,
              contentType: item.contentType,
              url: item.url,
              onTap: item.navigate,
            );
          }).toList(),
          onSeeAll: () => _navigateToBrowse('vod', 'Recently Added'),
        ));
      }

      setState(() {
        _rows = rows;
        _continueWatchingItems = continueWatchingItems;
        _recommendedItems = recommendedItems;
        _parentalLocked = parentalLocked;
        _isEmpty = rows.isEmpty;
        _isLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Recommended For You
  // ---------------------------------------------------------------------------

  /// Builds the mixed "Recommended For You" row.
  ///
  /// Extracts genre / group-title signals from the user's watch history and
  /// favourites, then matches them against the (parentally filtered) VOD and
  /// series lists. Live channels carry no genre metadata, so the most
  /// recently added channels are appended at the end of the row instead.
  /// When no history exists at all, the row falls back to the newest movies
  /// and series.
  ///
  /// Composition: up to 10 matched movies + 6 matched series + up to 4
  /// latest live channels, deduplicated against continue-watching items and
  /// favourites (those already have their own rows).
  Future<List<ContentItem>> _buildRecommendedItems({
    required List<VodItem> vodItems,
    required List<TvSery> seriesItems,
    required List<Channel> channels,
  }) async {
    final genreSignals = <String>{};
    final groupSignals = <String>{};

    // Content IDs to exclude: everything already in Continue Watching (plus
    // the parent series of in-progress episodes) and all favourites.
    final excluded = <String>{};

    // --- 1. Signals from watch history ------------------------------------
    try {
      final history =
          await _watchProgressService.getContinueWatching(limit: 20);
      for (final entry in history) {
        final origin = await _collectRecommendationSignals(
            entry.contentId, genreSignals, groupSignals);
        if (origin != null) excluded.add(origin);
      }
    } catch (_) {}

    // --- 2. Signals from favourites ----------------------------------------
    try {
      final favorites = await _favoritesService.getFavorites();
      for (final fav in favorites) {
        excluded.add(fav.contentId);
        await _collectRecommendationSignals(
            fav.contentId, genreSignals, groupSignals);
      }
    } catch (_) {}

    // --- 3. Match VOD / series against the signals -------------------------
    // The incoming lists are already newest-first, so both the matched and
    // fallback orderings surface fresh content.
    final hasHistory = genreSignals.isNotEmpty || groupSignals.isNotEmpty;
    final matchedVod = hasHistory
        ? vodItems
            .where((vod) => _matchesSignal(vod.genre, genreSignals) ||
                _matchesSignal(vod.groupTitle, groupSignals))
            .toList()
        : vodItems; // No history — fall back to newest movies.
    final matchedSeries = hasHistory
        ? seriesItems
            .where((s) => _matchesSignal(s.genre, genreSignals))
            .toList()
        : seriesItems; // No history — fall back to newest series.

    // --- 4. Compose the row -------------------------------------------------
    final items = <ContentItem>[];

    // Movies first (up to 10).
    var movieCount = 0;
    for (final vod in matchedVod) {
      if (movieCount >= 10) break;
      final contentId = 'vod:${vod.id}';
      if (excluded.contains(contentId)) continue;
      excluded.add(contentId);
      movieCount++;
      items.add(ContentItem(
        title: vod.title,
        imageUrl: vod.poster,
        contentId: contentId,
        contentType: 'vod',
        url: vod.url,
        onTap: () => _navigateToDetail(
          id: vod.id,
          title: vod.title,
          imageUrl: vod.poster,
          url: vod.url,
          groupTitle: vod.groupTitle,
          contentType: 'vod',
        ),
      ));
    }

    // Then series (up to 6).
    var seriesCount = 0;
    for (final s in matchedSeries) {
      if (seriesCount >= 6) break;
      final contentId = 'series:${s.id}';
      if (excluded.contains(contentId)) continue;
      excluded.add(contentId);
      seriesCount++;
      items.add(ContentItem(
        title: s.title,
        imageUrl: s.poster,
        contentId: contentId,
        contentType: 'series',
        onTap: () => _navigateToDetail(
          id: s.id,
          title: s.title,
          imageUrl: s.poster,
          url: '',
          contentType: 'series',
        ),
      ));
    }

    // Latest live channels at the end (up to 4). Channels have no genre
    // metadata, so this is discovery rather than genre matching. Note the
    // exclusion set keys channels as `live:<id>` (favourite/progress format).
    var channelCount = 0;
    for (final ch in channels) {
      if (channelCount >= 4) break;
      if (excluded.contains('live:${ch.id}')) continue;
      excluded.add('live:${ch.id}');
      channelCount++;
      items.add(ContentItem(
        title: ch.name,
        imageUrl: ch.logo,
        contentId: 'channel:${ch.id}',
        contentType: 'live',
        url: ch.url,
        onTap: () => _navigateToDetail(
          id: ch.id,
          title: ch.name,
          imageUrl: ch.logo,
          url: ch.url,
          groupTitle: ch.groupTitle,
          contentType: 'live',
        ),
      ));
    }

    return items;
  }

  /// Resolves a polymorphic [contentId] (`vod:<id>`, `series:<id>`,
  /// `episode:<id>`, `live:<id>`) and adds its genre / group-title to the
  /// signal sets.
  ///
  /// Returns the canonical row-level contentId that should be excluded from
  /// recommendations (e.g. the parent series for an in-progress episode), or
  /// `null` when the id cannot be parsed.
  Future<String?> _collectRecommendationSignals(
    String contentId,
    Set<String> genreSignals,
    Set<String> groupSignals,
  ) async {
    final parts = contentId.split(':');
    if (parts.length != 2) return null;
    final id = int.tryParse(parts[1]);
    if (id == null) return null;

    switch (parts[0]) {
      case 'vod':
        final vod = await (_db.select(_db.vodItems)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        if (vod != null) {
          _addSignalTokens(vod.genre, genreSignals);
          _addSignalTokens(vod.groupTitle, groupSignals);
        }
        return 'vod:$id';
      case 'series':
        final series = await (_db.select(_db.tvSeries)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        if (series != null) {
          _addSignalTokens(series.genre, genreSignals);
        }
        return 'series:$id';
      case 'episode':
        final episode = await (_db.select(_db.episodes)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        if (episode == null) return null;
        final series = await (_db.select(_db.tvSeries)
              ..where((t) => t.id.equals(episode.seriesId)))
            .getSingleOrNull();
        if (series != null) {
          _addSignalTokens(series.genre, genreSignals);
        }
        return 'series:${episode.seriesId}';
      case 'live':
        final channel = await (_db.select(_db.channels)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        if (channel != null) {
          _addSignalTokens(channel.groupTitle, groupSignals);
        }
        return 'live:$id';
      default:
        return null;
    }
  }

  /// Splits a comma-separated [value] (e.g. `"Action, Comedy"`) into
  /// lower-cased tokens added to [sink].
  void _addSignalTokens(String? value, Set<String> sink) {
    if (value == null || value.isEmpty) return;
    for (final token in value.split(',')) {
      final normalized = token.trim().toLowerCase();
      if (normalized.isNotEmpty) sink.add(normalized);
    }
  }

  /// Whether any comma-separated token of [value] matches a signal.
  bool _matchesSignal(String? value, Set<String> signals) {
    if (value == null || value.isEmpty || signals.isEmpty) return false;
    for (final token in value.split(',')) {
      final normalized = token.trim().toLowerCase();
      if (normalized.isNotEmpty && signals.contains(normalized)) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // User playlist helpers
  // ---------------------------------------------------------------------------

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
    print('[HomeScreen._getUserPlaylistIds] userId=$userId, '
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
      print('[HomeScreen._getUserPlaylistIds] No playlists matched '
          'userId filter — falling back to ALL playlists');
      playlists = await (_db.select(_db.playlists)).get();
    }

    final ids = playlists.map((p) => p.id).toList();
    // ignore: avoid_print
    print('[HomeScreen._getUserPlaylistIds] Returning ${ids.length} '
        'playlist IDs: $ids');
    return ids;
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
    await _loadContent();
  }

  // ---------------------------------------------------------------------------
  // Content resolution for Continue Watching
  // ---------------------------------------------------------------------------

  /// Resolves a polymorphic [contentId] (e.g. `"vod:5"`, `"episode:12"`)
  /// into a [ContinueWatchingItem] by looking up the corresponding database
  /// table.
  Future<ContinueWatchingItem?> _resolveContentItem(String contentId) async {
    final parts = contentId.split(':');
    if (parts.length != 2) return null;

    final type = parts[0];
    final id = int.tryParse(parts[1]);
    if (id == null) return null;

    final progress = await _watchProgressService.getProgress(contentId);
    if (progress == null) return null;
    final progressFraction =
        progress.durationMs > 0 ? progress.positionMs / progress.durationMs : 0.0;

    switch (type) {
      case 'live':
        final q = _db.select(_db.channels)..where((c) => c.id.equals(id));
        final ch = await q.getSingleOrNull();
        if (ch == null) return null;
        return ContinueWatchingItem(
          title: ch.name,
          imageUrl: ch.logo,
          progress: progressFraction,
          onTap: () => _navigateToDetail(
            id: ch.id,
            title: ch.name,
            imageUrl: ch.logo,
            url: ch.url,
            groupTitle: ch.groupTitle,
            contentType: 'live',
          ),
        );

      case 'vod':
        final q = _db.select(_db.vodItems)..where((v) => v.id.equals(id));
        final vod = await q.getSingleOrNull();
        if (vod == null) return null;
        return ContinueWatchingItem(
          title: vod.title,
          imageUrl: vod.poster,
          progress: progressFraction,
          onTap: () => _navigateToDetail(
            id: vod.id,
            title: vod.title,
            imageUrl: vod.poster,
            url: vod.url,
            groupTitle: vod.groupTitle,
            contentType: 'vod',
          ),
        );

      case 'episode':
        final q = _db.select(_db.episodes)..where((e) => e.id.equals(id));
        final ep = await q.getSingleOrNull();
        if (ep == null) return null;

        // Resolve the series title for the subtitle.
        final sq = _db.select(_db.tvSeries)
          ..where((s) => s.id.equals(ep.seriesId));
        final s = await sq.getSingleOrNull();
        final seriesTitle = s?.title ?? 'Series';

        return ContinueWatchingItem(
          title: seriesTitle,
          subtitle:
              'S${ep.season}:E${ep.episode} - ${ep.title}',
          imageUrl: ep.thumbnail,
          progress: progressFraction,
          onTap: () => _navigateToDetail(
            id: ep.id,
            title: ep.title,
            imageUrl: ep.thumbnail,
            url: ep.url,
            contentType: 'episode',
          ),
        );

      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _navigateToDetail({
    required int id,
    required String title,
    String? imageUrl,
    required String url,
    String? groupTitle,
    required String contentType,
  }) {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          id: id,
          title: title,
          imageUrl: imageUrl,
          url: url,
          groupTitle: groupTitle,
          contentType: contentType,
        ),
      ),
    )
        .then((_) {
      // Reload content in case data changed.
      _loadContent();
    });
  }

  void _navigateToBrowse(String contentType, String title) {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => BrowseScreen(
          contentType: contentType,
          title: title,
        ),
      ),
    )
        .then((_) => _loadContent());
  }

  void _navigateToImport() {
    Navigator.of(context)
        .push(
      MaterialPageRoute(builder: (_) => const ImportScreen()),
    )
        .then((_) => _loadContent());
  }

  void _navigateToDetailFromFavorite(Favorite fav) {
    // Parse the contentId to extract the numeric id (e.g. "vod:42" -> 42).
    final parts = fav.contentId.split(':');
    final id = parts.length == 2 ? int.tryParse(parts[1]) ?? 0 : 0;
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          id: id,
          title: fav.title ?? 'Untitled',
          imageUrl: fav.poster,
          url: fav.url ?? '',
          contentType: fav.contentType,
        ),
      ),
    )
        .then((_) => _loadContent());
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // On TV, skip the AppBar — the left rail handles top-level navigation.
    if (_isTv) {
      return _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: AppColors.accentPrimary,
              ),
            )
          : _isEmpty
              ? _buildEmptyState()
              : _buildContentRows();
    }

    return Scaffold(
      backgroundColor: AppColors.bgBase,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'iFlixify IPTV',
          style: TextStyle(
            color: AppColors.accentPrimary,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          // Unlock adult content button (shown when parental controls are on).
          if (_parentalLocked)
            IconButton(
              icon: const Icon(Icons.lock_outline, color: AppColors.accentPrimary),
              onPressed: _unlockAdultContent,
              tooltip: 'Unlock adult content',
            ),
          IconButton(
            icon: const Icon(Icons.search, color: AppColors.textPrimary),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SearchScreen(),
                ),
              );
            },
            tooltip: 'Search',
          ),
          IconButton(
            icon: const Icon(Icons.add, color: AppColors.textPrimary),
            onPressed: _navigateToImport,
            tooltip: 'Import Playlist',
          ),
          IconButton(
            icon: const Icon(Icons.person_outline, color: AppColors.textPrimary),
            onPressed: () {
              Navigator.of(context)
                  .push(
                MaterialPageRoute(
                  builder: (_) => const SettingsScreen(),
                ),
              )
                  .then((_) {
                // Reload when returning — preferences like adult content
                // visibility may have changed.
                _loadContent();
              });
            },
            tooltip: 'Settings',
          ),
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileSwitcherScreen()),
            ),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.accentPrimary,
              child: Text(
                _activeProfileInitials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // -- Import progress banner ----------------------------------------
          _buildImportBanner(),
          // -- Main content --------------------------------------------------
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.accentPrimary,
                    ),
                  )
                : _isEmpty
                    ? _buildEmptyState()
                    : _buildContentRows(),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Import progress banner
  // ---------------------------------------------------------------------------

  Widget _buildImportBanner() {
    final progress = _importProgress.progressNotifier.value;
    if (progress == null) return const SizedBox.shrink();

    final isActive = !progress.isComplete;
    final hasError = progress.hasError;
    final color = hasError
        ? Colors.redAccent
        : isActive
            ? AppColors.accentPrimary
            : Colors.greenAccent;
    final icon = hasError
        ? Icons.error_outline
        : isActive
            ? Icons.downloading
            : Icons.check_circle_outline;

    return Material(
      color: AppColors.bgElevated,
      child: InkWell(
        onTap: progress.isComplete ? _dismissImportBanner : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          progress.playlistName,
                          style: TextStyle(
                            color: color,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasError
                              ? progress.error ?? 'Import failed'
                              : progress.message,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (progress.isComplete && !hasError) ...[
                    Text(
                      '${progress.totalItems} items',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.close,
                        color: AppColors.textSecondary, size: 18),
                  ],
                  if (isActive) ...[
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress.progress > 0 ? progress.progress : null,
                        color: AppColors.accentPrimary,
                      ),
                    ),
                  ],
                ],
              ),
              if (isActive) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.progress > 0 ? progress.progress : null,
                    backgroundColor: AppColors.bgSurface,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppColors.accentPrimary),
                    minHeight: 3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.live_tv,
              size: 80,
              color: AppColors.accentPrimary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 24),
            const Text(
              'No playlist loaded yet',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'iFlixify IPTV lets you watch live TV, movies,\n'
              'and series from your IPTV provider.\n'
              'Import a playlist to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 240,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _navigateToImport,
                icon: const Icon(Icons.playlist_add, size: 20),
                label: const Text(
                  'Import your first playlist',
                  style: TextStyle(fontSize: 16),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentPrimary,
                  foregroundColor: AppColors.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onRefresh() async {
    await _loadContent();
  }

  Widget _buildContentRows() {
    // Total items: 1 optional Favorites row + 1 optional Continue Watching
    // row + 1 optional Recommended For You row + content rows.
    final hasFavorites = _favorites.isNotEmpty;
    final hasContinueWatching = _continueWatchingItems.isNotEmpty;
    final hasRecommended = _recommendedItems.isNotEmpty;
    final totalItems = _rows.length +
        (hasFavorites ? 1 : 0) +
        (hasContinueWatching ? 1 : 0) +
        (hasRecommended ? 1 : 0);

    return RefreshIndicator(
      color: AppColors.accentPrimary,
      backgroundColor: AppColors.bgElevated,
      onRefresh: _onRefresh,
      child: FocusTraversalGroup(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16),
          itemCount: totalItems,
          itemBuilder: (context, index) {
            // First slot: Continue Watching row (if present).
            if (hasContinueWatching && index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: ContinueWatchingRow(items: _continueWatchingItems),
              );
            }

            // Second slot: Recommended For You row (if present).
            final recommendedOffset = hasContinueWatching ? 1 : 0;
            if (hasRecommended && index == recommendedOffset) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: ContentRow(
                  label: 'Recommended For You',
                  isTv: _isTv,
                  items: _recommendedItems,
                ),
              );
            }

            // Third slot: Favorites row (if present).
            final favoritesOffset =
                recommendedOffset + (hasRecommended ? 1 : 0);
            if (hasFavorites && index == favoritesOffset) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: ContentRow(
                  label: 'Favorites',
                  isTv: _isTv,
                  autofocusFirst: _isTv,
                  items: _favorites.take(20).map((fav) {
                    return ContentItem(
                      title: fav.title ?? 'Untitled',
                      imageUrl: fav.poster,
                      contentId: fav.contentId,
                      contentType: fav.contentType,
                      url: fav.url,
                      onTap: () => _navigateToDetailFromFavorite(fav),
                    );
                  }).toList(),
                  onSeeAll: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const FavoritesScreen(),
                      ),
                    );
                  },
                ),
              );
            }

            // Remaining slots: standard content rows.
            final rowsOffset = favoritesOffset + (hasFavorites ? 1 : 0);
            final rowIndex = index - rowsOffset;
            return Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: _rows[rowIndex],
            );
          },
        ),
      ),
    );
  }
}

/// Lightweight holder used to merge items from different tables for the
/// "Recently Added" row and sort them by id.
class _RecentItem {
  const _RecentItem({
    required this.id,
    required this.title,
    this.imageUrl,
    required this.navigate,
    this.contentId,
    this.contentType,
    this.url,
  });

  final int id;
  final String title;
  final String? imageUrl;
  final VoidCallback navigate;
  final String? contentId;
  final String? contentType;
  final String? url;
}
