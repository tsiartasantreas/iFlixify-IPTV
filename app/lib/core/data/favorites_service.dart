import 'dart:async';

import 'package:drift/drift.dart' as drift;

import '../auth/profile_manager.dart';
import 'database.dart';
import 'supabase_client.dart';

/// Service for managing user favourites (bookmarks) in the local database.
///
/// Provides CRUD operations for the [Favorites] table with convenience
/// methods for toggling and checking favourite status.
///
/// Usage:
/// ```dart
/// final service = FavoritesService();
/// await service.addToFavorites(
///   contentId: 'vod:42',
///   contentType: 'vod',
///   title: 'Inception',
///   poster: 'https://...',
///   url: 'http://...',
/// );
/// final isFav = await service.isFavorite('vod:42');
/// ```
class FavoritesService {
  FavoritesService({
    AppDatabase? database,
    ProfileManager? profileManager,
  })  : _db = database ?? AppDatabase(),
        _profileManager = profileManager ?? ProfileManager.instance;

  final AppDatabase _db;
  final ProfileManager _profileManager;

  /// Prefixes [contentId] with the active profile ID so each profile has
  /// its own isolated favourites list.
  String _scopedId(String contentId) {
    final profileId = _profileManager.activeProfileId ?? 'default';
    return '$profileId:$contentId';
  }

  /// Adds an item to favourites.
  ///
  /// If the item is already favourited (same [contentId]), the existing
  /// record is updated with the latest title/poster/url.
  Future<void> addToFavorites({
    required String contentId,
    required String contentType,
    String? title,
    String? poster,
    String? url,
  }) async {
    final scopedId = _scopedId(contentId);
    await _db.into(_db.favorites).insertOnConflictUpdate(
          FavoritesCompanion.insert(
            contentId: scopedId,
            contentType: contentType,
            title: drift.Value(title),
            poster: drift.Value(poster),
            url: drift.Value(url),
            addedAt: DateTime.now(),
          ),
        );
    _pushToCloud();
  }

  /// Removes an item from favourites by its [contentId].
  Future<void> removeFromFavorites(String contentId) async {
    final scopedId = _scopedId(contentId);
    await (_db.delete(_db.favorites)
          ..where((t) => t.contentId.equals(scopedId)))
        .go();
    _pushToCloud();
  }

  /// Returns `true` if the item with [contentId] is in favourites.
  Future<bool> isFavorite(String contentId) async {
    final scopedId = _scopedId(contentId);
    final count = await (_db.selectOnly(_db.favorites)
          ..addColumns([_db.favorites.contentId.count()])
          ..where(_db.favorites.contentId.equals(scopedId)))
        .getSingle();
    return (count.read(_db.favorites.contentId.count()) ?? 0) > 0;
  }

  /// Toggles favourite status: removes if present, adds if not.
  ///
  /// Returns `true` if the item is now favourited, `false` if removed.
  /// The cloud push fires exactly once via [addToFavorites] or
  /// [removeFromFavorites].
  Future<bool> toggleFavorite({
    required String contentId,
    required String contentType,
    String? title,
    String? poster,
    String? url,
  }) async {
    if (await isFavorite(contentId)) {
      await removeFromFavorites(contentId);
      return false;
    } else {
      await addToFavorites(
        contentId: contentId,
        contentType: contentType,
        title: title,
        poster: poster,
        url: url,
      );
      return true;
    }
  }

  /// Returns all favourites ordered by most recently added.
  Future<List<Favorite>> getFavorites() async {
    final profileId = _profileManager.activeProfileId ?? 'default';
    final prefix = '$profileId:';
    final all = await (_db.select(_db.favorites)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.addedAt)]))
        .get();
    return all.where((f) => f.contentId.startsWith(prefix)).toList();
  }

  /// Returns favourites filtered by [contentType], ordered by most recently
  /// added.
  Future<List<Favorite>> getFavoritesByType(String contentType) async {
    final profileId = _profileManager.activeProfileId ?? 'default';
    final prefix = '$profileId:';
    final all = await (_db.select(_db.favorites)
          ..where((t) => t.contentType.equals(contentType))
          ..orderBy([(t) => drift.OrderingTerm.desc(t.addedAt)]))
        .get();
    return all.where((f) => f.contentId.startsWith(prefix)).toList();
  }

  // ---------------------------------------------------------------------------
  // Cloud sync (cross-device favourites)
  // ---------------------------------------------------------------------------

  /// Ensures Supabase is initialized and returns the current user id.
  ///
  /// Returns `null` (meaning "cannot sync") when initialization fails or no
  /// user is signed in.
  Future<String?> _cloudUserId() async {
    if (!SupabaseService.isInitialized) {
      try {
        await SupabaseService.initialize();
      } catch (e) {
        // Offline / misconfigured — stay local-only.
        // ignore: avoid_print
        print('[FavoritesService] Supabase init failed: $e');
        return null;
      }
    }
    return SupabaseService.client.auth.currentUser?.id;
  }

  /// Pushes all local favourites to the Supabase `favorites_sync` table.
  ///
  /// Rows are upserted on the `(user_id, content_id)` conflict target, so
  /// repeated calls are safe. No-op when Supabase is unavailable or nobody is
  /// signed in. Network errors are logged and swallowed — local writes must
  /// never fail because of the cloud.
  Future<void> syncToCloud() async {
    final userId = await _cloudUserId();
    if (userId == null) return;

    try {
      final favorites = await getFavorites();
      if (favorites.isEmpty) return;

      final rows = favorites
          .map(
            (f) => {
              'user_id': userId,
              'content_id': f.contentId,
              'added_at': f.addedAt.toIso8601String(),
            },
          )
          .toList();

      // Upsert in batches of 50 (same strategy as watch progress sync).
      const batchSize = 50;
      for (var i = 0; i < rows.length; i += batchSize) {
        final batch = rows.sublist(
          i,
          (i + batchSize).clamp(0, rows.length),
        );
        await SupabaseService.client.from('favorites_sync').upsert(
              batch,
              onConflict: 'user_id,content_id',
            );
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FavoritesService] syncToCloud failed: $e');
    }
  }

  /// Pulls cloud favourites into the local database (merge strategy).
  ///
  /// Cloud rows whose `content_id` also exists locally update the local
  /// [Favorite.addedAt] when the cloud timestamp is newer (last-write-wins).
  /// Rows that only exist in the cloud are skipped: `favorites_sync` carries
  /// no title/poster metadata, so a local record is required to display the
  /// favourite. Local favourites missing from the cloud are never deleted.
  Future<void> syncFromCloud() async {
    final userId = await _cloudUserId();
    if (userId == null) return;

    try {
      final response = await SupabaseService.client
          .from('favorites_sync')
          .select()
          .eq('user_id', userId);

      for (final row in response) {
        final contentId = row['content_id'] as String;
        final cloudAddedAt = DateTime.parse(row['added_at'] as String);

        // Merge only where a local record exists.
        final local = await (_db.select(_db.favorites)
              ..where((t) => t.contentId.equals(contentId)))
            .getSingleOrNull();
        if (local == null) continue;

        // Only overwrite if the cloud entry is newer.
        if (cloudAddedAt.isAfter(local.addedAt)) {
          await (_db.update(_db.favorites)
                ..where((t) => t.contentId.equals(contentId)))
              .write(FavoritesCompanion(addedAt: drift.Value(cloudAddedAt)));
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FavoritesService] syncFromCloud failed: $e');
    }
  }

  /// Fire-and-forget cloud push used after local mutations.
  ///
  /// [syncToCloud] logs and swallows all of its own errors, so this never
  /// throws and never delays the caller.
  void _pushToCloud() {
    unawaited(syncToCloud());
  }
}
