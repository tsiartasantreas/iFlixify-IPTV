import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';

import '../../core/data/database.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/netflix_card.dart';
import '../../core/widgets/netflix_focus.dart';
import '../detail/detail_screen.dart';

/// Netflix-style "My List" favourites screen.
///
/// Displays a grid of favorited items (channels, VOD, series) with poster /
/// thumbnail images. Supports tap to navigate to detail and long-press to
/// remove from favourites. Shows an empty state when no favourites exist.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({
    super.key,
    this.database,
    this.tabChangeNotifier,
    this.tabIndex = 0,
  });

  /// Database instance -- injectable for testing.
  final AppDatabase? database;

  /// Notifier from the parent shell that fires when the active tab changes.
  final ValueNotifier<int>? tabChangeNotifier;

  /// The index of this tab in the parent shell's navigation.
  final int tabIndex;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  AppDatabase? _db;
  List<_FavoriteItem> _items = [];
  bool _isLoading = true;

  /// Tracks the last seen tab-change notifier value so we only reload when
  /// the tab actually changes (not on the initial build).
  int _lastSeenChangeCount = 0;

  bool get _isTv =>
      Platform.isLinux ||
      (Platform.isAndroid &&
          MediaQueryData.fromView(
                      WidgetsBinding.instance.platformDispatcher.views.first)
                  .size
                  .shortestSide >
              960);

  @override
  void initState() {
    super.initState();
    _db = widget.database;
    _loadFavorites();
    // Listen for tab changes from the parent shell.
    widget.tabChangeNotifier?.addListener(_onTabChange);
  }

  @override
  void dispose() {
    widget.tabChangeNotifier?.removeListener(_onTabChange);
    super.dispose();
  }

  /// Called when the parent shell switches tabs. Reloads favorites if this
  /// screen just became visible (skips the initial build).
  void _onTabChange() {
    if (!mounted) return;
    final currentValue = widget.tabChangeNotifier!.value;
    if (currentValue == _lastSeenChangeCount) return;
    _lastSeenChangeCount = currentValue;
    _loadFavorites();
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadFavorites() async {
    setState(() => _isLoading = true);

    if (_db == null) {
      if (mounted) {
        setState(() {
          _items = [];
          _isLoading = false;
        });
      }
      return;
    }

    final favorites = await (_db!.select(_db!.favorites)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.addedAt)]))
        .get();

    final items = <_FavoriteItem>[];
    for (final fav in favorites) {
      final item = await _resolveFavorite(fav);
      if (item != null) {
        items.add(item);
      }
    }

    if (mounted) {
      setState(() {
        _items = items;
        _isLoading = false;
      });
    }
  }

  /// Resolves a [Favorite] record to a displayable [_FavoriteItem] by
  /// looking up the actual content in the relevant table.
  Future<_FavoriteItem?> _resolveFavorite(Favorite fav) async {
    // Parse polymorphic ID: "channel:42", "vod:7", "series:19".
    final parts = fav.contentId.split(':');
    if (parts.length != 2) return null;

    final type = parts[0];
    final idStr = parts[1];
    final id = int.tryParse(idStr);
    if (id == null) return null;

    switch (type) {
      case 'channel':
        final channels = await (_db!.select(_db!.channels)
              ..where((t) => t.id.equals(id)))
            .get();
        if (channels.isEmpty) return null;
        final ch = channels.first;
        return _FavoriteItem(
          contentId: fav.contentId,
          contentType: 'live',
          title: ch.name,
          imageUrl: ch.logo,
          entityId: ch.id,
          url: ch.url,
          groupTitle: ch.groupTitle,
          addedAt: fav.addedAt,
        );

      case 'vod':
        final vods = await (_db!.select(_db!.vodItems)
              ..where((t) => t.id.equals(id)))
            .get();
        if (vods.isEmpty) return null;
        final vod = vods.first;
        return _FavoriteItem(
          contentId: fav.contentId,
          contentType: 'vod',
          title: vod.title,
          imageUrl: vod.poster,
          entityId: vod.id,
          url: vod.url,
          groupTitle: vod.groupTitle,
          addedAt: fav.addedAt,
        );

      case 'series':
        final seriesList = await (_db!.select(_db!.tvSeries)
              ..where((t) => t.id.equals(id)))
            .get();
        if (seriesList.isEmpty) return null;
        final series = seriesList.first;
        return _FavoriteItem(
          contentId: fav.contentId,
          contentType: 'series',
          title: series.title,
          imageUrl: series.poster,
          entityId: series.id,
          url: '',
          groupTitle: null,
          addedAt: fav.addedAt,
        );

      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _removeFavorite(_FavoriteItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Remove from My List?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          '"${item.title}" will be removed from your favourites.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Remove',
              style: TextStyle(color: AppColors.accentPrimary),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (_db != null) {
        await (_db!.delete(_db!.favorites)
              ..where((t) => t.contentId.equals(item.contentId)))
            .go();
      }

      if (mounted) {
        setState(() {
          _items.removeWhere((i) => i.contentId == item.contentId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"${item.title}" removed from My List'),
            backgroundColor: AppColors.bgSurface,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _navigateToDetail(_FavoriteItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          id: item.entityId,
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

  Future<void> _onRefresh() async {
    await _loadFavorites();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accentPrimary),
      );
    }

    if (_items.isEmpty) {
      return _buildEmptyState();
    }

    return RefreshIndicator(
      color: AppColors.accentPrimary,
      backgroundColor: AppColors.bgElevated,
      onRefresh: _onRefresh,
      child: _buildGrid(),
    );
  }

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.playlist_play,
            size: 64,
            color: AppColors.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          const Text(
            'My List is Empty',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Browse and tap the + icon to add\nfavourites to your list.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Grid
  // ---------------------------------------------------------------------------

  Widget _buildGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Determine grid columns based on available width.
        final cardWidth = _isTv ? AppTheme.tvCardWidth : AppTheme.cardWidth;
        final columns = (constraints.maxWidth / (cardWidth + AppTheme.cardSpacing))
            .floor()
            .clamp(2, 8);

        return CustomScrollView(
          slivers: [
            // -- Header -----------------------------------------------------
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.horizontalPadding,
                  16,
                  AppTheme.horizontalPadding,
                  12,
                ),
                child: Row(
                  children: [
                    const Text(
                      'My List',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_items.length} items',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // -- Grid -------------------------------------------------------
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.horizontalPadding,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  childAspectRatio: AppTheme.posterAspectRatio,
                  crossAxisSpacing: AppTheme.cardSpacing,
                  mainAxisSpacing: AppTheme.rowSpacing,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = _items[index];
                    return _buildFavoriteCard(item);
                  },
                  childCount: _items.length,
                ),
              ),
            ),

            // Bottom padding.
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Favorite card
  // ---------------------------------------------------------------------------

  Widget _buildFavoriteCard(_FavoriteItem item) {
    return NetflixFocus(
      isTv: _isTv,
      child: GestureDetector(
        onTap: () => _navigateToDetail(item),
        onLongPress: () => _removeFavorite(item),
        child: Stack(
          children: [
            // Card content.
            NetflixCard(
              title: item.title,
              imageUrl: item.imageUrl,
              isTv: _isTv,
              contentType: item.contentType,
              onTap: () => _navigateToDetail(item),
            ),

            // Remove button (top-right corner).
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: () => _removeFavorite(item),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.bgBase.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.remove,
                    color: AppColors.textSecondary,
                    size: 16,
                  ),
                ),
              ),
            ),

            // Content type badge.
            Positioned(
              bottom: 32,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accentPrimary.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  _contentTypeLabel(item.contentType),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _contentTypeLabel(String contentType) {
    switch (contentType) {
      case 'live':
        return 'LIVE';
      case 'vod':
        return 'MOVIE';
      case 'series':
        return 'SERIES';
      default:
        return contentType.toUpperCase();
    }
  }
}

// ---------------------------------------------------------------------------
// Internal models
// ---------------------------------------------------------------------------

/// A resolved favourite item ready for display.
class _FavoriteItem {
  const _FavoriteItem({
    required this.contentId,
    required this.contentType,
    required this.title,
    this.imageUrl,
    required this.entityId,
    required this.url,
    this.groupTitle,
    required this.addedAt,
  });

  final String contentId;
  final String contentType;
  final String title;
  final String? imageUrl;
  final int entityId;
  final String url;
  final String? groupTitle;
  final DateTime addedAt;
}
