import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../auth/profile_manager.dart';
import '../data/database.dart';
import '../entitlement/entitlement_service.dart';
import 'supabase_client.dart';

// Parameter names intentionally differ from field names (authService vs
// _authService, client vs _client), so the initializer list is the correct
// pattern here.
// ignore_for_file: prefer_initializing_formals

/// Manages watch progress for Continue Watching / Up Next features.
///
/// Persists playback position locally via [AppDatabase] and optionally
/// syncs to Supabase for cross-device resume (Pro only).
class WatchProgressService {
  WatchProgressService({
    AppDatabase? database,
    EntitlementService? entitlementService,
    AuthService? authService,
    SupabaseClient? client,
    ProfileManager? profileManager,
  })  : _db = database,
        _entitlement = entitlementService,
        _authService = authService,
        _client = client,
        _profileManager = profileManager ?? ProfileManager.instance;

  final AppDatabase? _db;
  final EntitlementService? _entitlement;
  final AuthService? _authService;
  final SupabaseClient? _client;
  final ProfileManager _profileManager;

  AppDatabase get _database => _db ?? AppDatabase();

  SupabaseClient get _supabase =>
      _client ??
      (SupabaseService.isInitialized ? SupabaseService.client : throw StateError(
        'Supabase not initialized',
      ));

  /// Returns the current Supabase user ID, or `null` if not signed in.
  String? get _userId {
    final user = _authService?.currentUser ??
        (SupabaseService.isInitialized
            ? SupabaseService.client.auth.currentUser
            : null);
    return user?.id;
  }

  bool get _isPro => _entitlement?.isPro ?? false;

  /// Prefixes [contentId] with the active profile ID so each profile has
  /// its own isolated watch progress.
  String _scopedId(String contentId) {
    // Prefix with active profile ID so each profile has its own progress
    final profileId = _profileManager.activeProfileId ?? 'default';
    return '$profileId:$contentId';
  }

  // ---------------------------------------------------------------------------
  // Local CRUD
  // ---------------------------------------------------------------------------

  /// Saves playback [positionMs] for [contentId].
  ///
  /// If the item was already watched past 95% of [durationMs] the entry is
  /// cleared instead (treated as completed).
  Future<void> saveProgress(
    String contentId,
    int positionMs,
    int durationMs,
  ) async {
    if (durationMs <= 0) return;

    final scopedId = _scopedId(contentId);

    // Treat >= 95% watched as "completed" — remove from continue watching.
    if (positionMs >= durationMs * 0.95) {
      await clearProgress(contentId);
      return;
    }

    await _database.into(_database.watchProgressEntry).insertOnConflictUpdate(
      WatchProgressEntryCompanion(
        contentId: Value(scopedId),
        positionMs: Value(positionMs),
        durationMs: Value(durationMs),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Returns saved progress for [contentId], or `null` if none exists.
  ///
  /// Looks up the profile-scoped entry first, then falls back to a legacy
  /// entry (without profile prefix) for backward compatibility.
  Future<WatchProgressEntryData?> getProgress(String contentId) async {
    final scopedId = _scopedId(contentId);
    final query = _database.select(_database.watchProgressEntry)
      ..where((w) => w.contentId.equals(scopedId));
    final result = await query.getSingleOrNull();
    if (result != null) return result;

    // Fallback: try the legacy (unscoped) contentId.
    final legacyQuery = _database.select(_database.watchProgressEntry)
      ..where((w) => w.contentId.equals(contentId));
    return legacyQuery.getSingleOrNull();
  }

  /// Returns up to [limit] items with saved progress, most recently updated.
  ///
  /// Items not yet started (0% played) are excluded.
  ///
  /// Includes both profile-scoped entries (prefix `"<profileId>:"`) and
  /// legacy entries (no prefix) so that data saved before the profile-scoping
  /// migration is not silently lost.
  Future<List<WatchProgressEntryData>> getContinueWatching({
    int limit = 10,
  }) async {
    final profileId = _profileManager.activeProfileId ?? 'default';
    final prefix = '$profileId:';
    final allEntries = await _database.select(_database.watchProgressEntry).get();
    // Filter in Dart: keep items belonging to the active profile (or legacy
    // items with no profile prefix), where position > 0 and position < 95%
    // (exclude completed). Accidental taps are guarded by the 30 s minimum
    // resume gate in the player/detail screens.
    final filtered = allEntries.where((e) {
      // Accept entries scoped to the active profile.
      final isScoped = e.contentId.startsWith(prefix);
      // Accept legacy entries that have no profile prefix at all.
      // A profile-scoped id looks like "<profileId>:type:id" (3 colon-parts),
      // while a legacy id looks like "type:id" (2 colon-parts).
      final isLegacy = !isScoped && e.contentId.split(':').length == 2;
      // Accept rows saved under the literal 'default' scope: _scopedId writes
      // 'default:<id>' whenever no active profile was known at save time
      // (cache not yet populated), so those rows belong to no particular
      // profile and must remain visible once a profile becomes active.
      // Without this, rows the service itself wrote are silently dropped by
      // the reader ("saved but never shown" Continue Watching failure).
      final isDefaultScoped =
          !isScoped && !isLegacy && e.contentId.startsWith('default:');
      if (!isScoped && !isLegacy && !isDefaultScoped) return false;
      if (e.durationMs <= 0) return false;
      final fraction = e.positionMs / e.durationMs;
      return fraction > 0 && fraction < 0.95;
    }).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return filtered.take(limit).toList();
  }

  /// Clears saved progress for [contentId].
  ///
  /// Deletes BOTH the profile-scoped row and the raw (legacy, unscoped) row
  /// so that completion cannot be "resurrected" by [getProgress]'s legacy
  /// fallback.
  Future<void> clearProgress(String contentId) async {
    final scoped = _scopedId(contentId);
    await (_database.delete(_database.watchProgressEntry)
          ..where((w) => w.contentId.equals(scoped) | w.contentId.equals(contentId)))
        .go();
  }

  /// Returns the next unwatched episode info for a series, given the current
  /// [contentId] (format: `"episode:<id>"`).
  ///
  /// Returns `null` if the content is not an episode or if there is no next
  /// episode in the series.
  Future<EpisodeUpNext?> getUpNext(String contentId) async {
    // Tolerate profile-scoped ids ("<profileId>:episode:<id>"): strip the
    // leading prefix part before parsing.
    var parts = contentId.split(':');
    if (parts.length == 3 &&
        (parts[0] == 'default' || int.tryParse(parts[0]) != null)) {
      parts = parts.sublist(1);
    }
    if (parts.length != 2 || parts[0] != 'episode') return null;

    final episodeId = int.tryParse(parts[1]);
    if (episodeId == null) return null;

    // Fetch the current episode.
    final currentEpisodeQuery = _database.select(_database.episodes)
      ..where((e) => e.id.equals(episodeId));
    final currentEpisode = await currentEpisodeQuery.getSingleOrNull();
    if (currentEpisode == null) return null;

    // Find the next episode (same series, same or next season, higher episode
    // number).
    final nextEpisodeQuery = _database.select(_database.episodes)
      ..where(
        (e) =>
            e.seriesId.equals(currentEpisode.seriesId) &
            ((e.season.equals(currentEpisode.season) &
                e.episode.isBiggerThanValue(currentEpisode.episode)) |
            e.season.isBiggerThanValue(currentEpisode.season)),
      )
      ..orderBy([
        (e) => OrderingTerm.asc(e.season),
        (e) => OrderingTerm.asc(e.episode),
      ])
      ..limit(1);
    final nextEpisode = await nextEpisodeQuery.getSingleOrNull();
    if (nextEpisode == null) return null;

    // Fetch series metadata.
    final seriesQuery = _database.select(_database.tvSeries)
      ..where((s) => s.id.equals(currentEpisode.seriesId));
    final series = await seriesQuery.getSingleOrNull();

    return EpisodeUpNext(
      episodeId: nextEpisode.id,
      seriesId: nextEpisode.seriesId,
      seriesTitle: series?.title ?? 'Series',
      season: nextEpisode.season,
      episode: nextEpisode.episode,
      title: nextEpisode.title,
      url: nextEpisode.url,
      thumbnail: nextEpisode.thumbnail,
    );
  }

  // ---------------------------------------------------------------------------
  // Cloud sync (Pro only)
  // ---------------------------------------------------------------------------

  /// Syncs all local progress to the Supabase `watch_progress_sync` table.
  ///
  /// Rows are keyed by the CLOUD profile identity: the locally scoped
  /// content id (`"<localProfileId>:<rawId>"`) is split and pushed as
  /// `(profile_id, content_id: rawId)`. Because `user_profiles.profile_id`
  /// equals the local profile id per user (see
  /// [ProfileManager.localToCloudIdMap]), the pushed profile_id is portable
  /// across devices — the device-specific local autoincrement never leaks
  /// into the cloud key. Legacy unscoped rows are pushed under profile_id 0.
  ///
  /// Deletions are reconciled: cloud rows that no longer exist locally
  /// (cleared progress) are removed so [syncFromCloud] cannot resurrect
  /// them. Does nothing for free-tier users or when no user is signed in.
  Future<void> syncToCloud() async {
    if (!_isPro || _userId == null) return;

    final entries = await _database.select(_database.watchProgressEntry).get();

    final rows = <Map<String, dynamic>>[];
    final localKeys = <String>{};
    for (final e in entries) {
      final (profileId, rawId) = ProfileManager.resolveScopedId(e.contentId);
      localKeys.add('$profileId:$rawId');
      rows.add({
        'user_id': _userId,
        'profile_id': profileId,
        'content_id': rawId,
        'position_ms': e.positionMs,
        'duration_ms': e.durationMs,
        'updated_at': e.updatedAt.toIso8601String(),
      });
    }

    if (rows.isNotEmpty) {
      // Upsert in batches of 50.
      const batchSize = 50;
      for (var i = 0; i < rows.length; i += batchSize) {
        final batch = rows.sublist(
          i,
          (i + batchSize).clamp(0, rows.length),
        );
        await _supabase.from('watch_progress_sync').upsert(
              batch,
              onConflict: 'user_id,profile_id,content_id',
            );
      }
    }

    await _reconcileCloudDeletions(localKeys);
  }

  /// Removes cloud rows that no longer correspond to any local entry.
  ///
  /// Rows written before per-profile scoping stored the LOCALLY scoped id
  /// as content_id (profile_id defaulting to 0); those are resolved via
  /// [_resolveCloudRow] and replaced by their new-format equivalent on the
  /// next push, so they are treated as stale as soon as the local state
  /// represents the same data.
  Future<void> _reconcileCloudDeletions(Set<String> localKeys) async {
    final cloudRows = await _supabase
        .from('watch_progress_sync')
        .select('profile_id,content_id')
        .eq('user_id', _userId!);

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

      await _supabase.from('watch_progress_sync').delete().match({
        'user_id': _userId!,
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

  /// Pulls cloud progress into the local database (Pro only).
  ///
  /// Cloud rows are keyed by `(profile_id, raw content id)`; the local
  /// profile-scoped id is rebuilt as `"<profileId>:<rawId>"` (cloud profile
  /// ids equal local profile ids per user — see
  /// [ProfileManager.localToCloudIdMap]). Rows for profiles that do not
  /// exist locally yet are still written: profile sync runs first in
  /// [SyncCoordinator.fullSync]. Legacy rows (profile_id 0) are written
  /// unscoped so the legacy fallback keeps finding them.
  ///
  /// Cloud entries that are newer than the local copy overwrite the local
  /// version. Entries that exist only locally are left untouched.
  Future<void> syncFromCloud() async {
    if (!_isPro || _userId == null) return;

    final response = await _supabase
        .from('watch_progress_sync')
        .select()
        .eq('user_id', _userId!);

    for (final row in response) {
      final (profileId, rawId) = _resolveCloudRow(row);
      final localId = profileId > 0 ? '$profileId:$rawId' : rawId;
      final positionMs = row['position_ms'] as int;
      final durationMs = (row['duration_ms'] as int?) ?? 0;
      final updatedAt = DateTime.parse(row['updated_at'] as String);

      // Only overwrite if the cloud entry is newer.
      final local = await (_database.select(_database.watchProgressEntry)
            ..where((w) => w.contentId.equals(localId)))
          .getSingleOrNull();
      if (local == null || updatedAt.isAfter(local.updatedAt)) {
        await _database.into(_database.watchProgressEntry).insertOnConflictUpdate(
          WatchProgressEntryCompanion(
            contentId: Value(localId),
            positionMs: Value(positionMs),
            durationMs: Value(durationMs),
            updatedAt: Value(updatedAt),
          ),
        );
      }
    }
  }
}

/// Data class for the "Up Next" episode recommendation.
class EpisodeUpNext {
  const EpisodeUpNext({
    required this.episodeId,
    required this.seriesId,
    required this.seriesTitle,
    required this.season,
    required this.episode,
    required this.title,
    required this.url,
    this.thumbnail,
  });

  final int episodeId;
  final int seriesId;
  final String seriesTitle;
  final int season;
  final int episode;
  final String title;
  final String url;
  final String? thumbnail;

  /// Formatted label like "S1:E3 - Episode Title".
  String get label => 'S$season:E$episode - $title';

  /// Polymorphic content key for this episode.
  String get contentId => 'episode:$episodeId';
}
