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

  /// Pushes ALL local favourites (every profile) to the Supabase
  /// `favorites_sync` table.
  ///
  /// Rows are keyed by the CLOUD profile identity: the locally scoped
  /// content id (`"<localProfileId>:<rawId>"`) is split and pushed as
  /// `(profile_id, content_id: rawId)`. Because `user_profiles.profile_id`
  /// equals the local profile id per user (see
  /// [ProfileManager.localToCloudIdMap]), the pushed profile_id is portable
  /// across devices. Legacy unscoped rows are pushed under profile_id 0.
  ///
  /// Upsert on `(user_id, profile_id, content_id)` makes repeated calls
  /// safe. Deletions are reconciled: cloud rows that no longer exist
  /// locally are removed so [syncFromCloud] cannot resurrect removed
  /// favourites. No-op when Supabase is unavailable or nobody is signed
  /// in. Network errors are logged and swallowed — local writes must never
  /// fail because of the cloud.
  Future<void> syncToCloud() async {
    final userId = await _cloudUserId();
    if (userId == null) return;

    try {
      final favorites = await _db.select(_db.favorites).get();

      final rows = <Map<String, dynamic>>[];
      final localKeys = <String>{};
      for (final f in favorites) {
        final (profileId, rawId) = ProfileManager.resolveScopedId(f.contentId);
        localKeys.add('$profileId:$rawId');
        rows.add({
          'user_id': userId,
          'profile_id': profileId,
          'content_id': rawId,
          'added_at': f.addedAt.toIso8601String(),
        });
      }

      if (rows.isNotEmpty) {
        // Upsert in batches of 50 (same strategy as watch progress sync).
        const batchSize = 50;
        for (var i = 0; i < rows.length; i += batchSize) {
          final batch = rows.sublist(
            i,
            (i + batchSize).clamp(0, rows.length),
          );
          await SupabaseService.client.from('favorites_sync').upsert(
                batch,
                onConflict: 'user_id,profile_id,content_id',
              );
        }
      }

      await _reconcileCloudDeletions(userId, localKeys);
    } catch (e) {
      // ignore: avoid_print
      print('[FavoritesService] syncToCloud failed: $e');
    }
  }

  /// Removes cloud rows that no longer correspond to any local favourite.
  ///
  /// Rows written before per-profile scoping stored the LOCALLY scoped id
  /// as content_id (profile_id defaulting to 0); those are resolved via
  /// [_resolveCloudRow] and replaced by their new-format equivalent on the
  /// next push, so they are treated as stale as soon as the local state
  /// represents the same data.
  Future<void> _reconcileCloudDeletions(
    String userId,
    Set<String> localKeys,
  ) async {
    final cloudRows = await SupabaseService.client
        .from('favorites_sync')
        .select('profile_id,content_id')
        .eq('user_id', userId);

    for (final row in cloudRows) {
      final (profileId, rawId) = _resolveCloudRow(row);
      final resolvedKey = '$profileId:$rawId';
      final storedProfile = (row['profile_id'] as int?) ?? 0;
      final storedContent = row['content_id'] as String;
      final storedKey = '$storedProfile:$storedContent';

      // Keep only rows already stored in the new format whose data still
      // exists locally. Legacy-format rows (resolvedKey != storedKey) are
      // always re-pushed in the new format, so they are stale too.
      if (resolvedKey == storedKey && localKeys.contains(resolvedKey)) {
        continue;
      }

      await SupabaseService.client.from('favorites_sync').delete().match({
        'user_id': userId,
        'profile_id': storedProfile,
        'content_id': storedContent,
      });
    }
  }

  /// Resolves a cloud row to `(profileId, rawContentId)`.
  ///
  /// Rows written before per-profile scoping stored the LOCALLY scoped id
  /// (or a legacy raw id) in content_id with profile_id defaulting to 0;
  /// the profile prefix is recovered so those rows map onto the same cloud
  /// identity as new-format rows.
  (int, String) _resolveCloudRow(Map<String, dynamic> row) {
    final profileId = (row['profile_id'] as int?) ?? 0;
    final contentId = row['content_id'] as String;
    if (profileId != 0) return (profileId, contentId);
    final (head, rest) = ProfileManager.splitScopedId(contentId);
    if (head == 'default') return (0, rest);
    final parsed = int.tryParse(head);
    return parsed != null ? (parsed, rest) : (0, contentId);
  }

  /// Pulls cloud favourites into the local database (merge + restore).
  ///
  /// Cloud rows are keyed by `(profile_id, raw content id)`; the local
  /// profile-scoped id is rebuilt as `"<profileId>:<rawId>"` (cloud profile
  /// ids equal local profile ids per user — see
  /// [ProfileManager.localToCloudIdMap]). Legacy rows (profile_id 0) are
  /// written unscoped.
  ///
  /// Cloud rows that do not exist locally are RESTORED (insert-only) so a
  /// fresh device gets the full per-profile favourites list back: the
  /// content type is derived from the raw id prefix, and title/poster/url
  /// are filled in lazily by the UI the next time the item is opened.
  /// Rows that exist locally are updated when the cloud timestamp is newer
  /// (last-write-wins). Local favourites missing from the cloud are never
  /// deleted.
  Future<void> syncFromCloud() async {
    final userId = await _cloudUserId();
    if (userId == null) return;

    try {
      final response = await SupabaseService.client
          .from('favorites_sync')
          .select()
          .eq('user_id', userId);

      for (final row in response) {
        final (profileId, rawId) = _resolveCloudRow(row);
        final localId = profileId > 0 ? '$profileId:$rawId' : rawId;
        final cloudAddedAt = DateTime.parse(row['added_at'] as String);

        final local = await (_db.select(_db.favorites)
              ..where((t) => t.contentId.equals(localId)))
            .getSingleOrNull();

        if (local == null) {
          // Restore a favourite that only exists in the cloud.
          final parts = rawId.split(':');
          final contentType =
              parts.length >= 2 && parts.first.isNotEmpty ? parts.first : 'unknown';
          await _db.into(_db.favorites).insert(
                FavoritesCompanion.insert(
                  contentId: localId,
                  contentType: contentType,
                  addedAt: cloudAddedAt,
                ),
              );
        } else if (cloudAddedAt.isAfter(local.addedAt)) {
          // Only overwrite if the cloud entry is newer.
          await (_db.update(_db.favorites)
                ..where((t) => t.contentId.equals(localId)))
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
  /// Pulls before pushing so deletion reconciliation always sees the
  /// complete cloud state — a bare push would consider not-yet-pulled rows
  /// stale and delete them. [syncToCloud] and [syncFromCloud] log and
  /// swallow all of their own errors, so this never throws and never
  /// delays the caller.
  void _pushToCloud() {
    unawaited(_syncNow());
  }

  Future<void> _syncNow() async {
    await syncFromCloud();
    await syncToCloud();
  }
}
