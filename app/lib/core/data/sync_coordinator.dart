import 'dart:async';

import '../auth/profile_manager.dart';
import '../entitlement/entitlement_service.dart';
import 'favorites_service.dart';
import 'playlist_sync_service.dart';
import 'supabase_client.dart';
import 'watch_progress_service.dart';

/// Coordinates two-way cloud sync across local persistence services
/// (profiles, favourites, watch progress, playlists).
///
/// Use [maybeFullSync] after sign-in and on app open for returning users; it
/// is a safe no-op when Supabase is unavailable or nobody is signed in.
///
/// Usage:
/// ```dart
/// unawaited(SyncCoordinator.maybeFullSync());
/// ```
class SyncCoordinator {
  SyncCoordinator._() {
    _watchProgressService = WatchProgressService(
      entitlementService: _entitlementService,
    );
  }

  /// Shared singleton instance.
  static final SyncCoordinator instance = SyncCoordinator._();

  /// Guards against overlapping syncs (the coordinator is fire-and-forget
  /// from several places: login, app open, settings refresh).
  static bool _syncing = false;

  final FavoritesService _favoritesService = FavoritesService();
  final EntitlementService _entitlementService = EntitlementService();
  late final WatchProgressService _watchProgressService;

  /// Runs [fullSync] only when Supabase is initialized and a user is signed
  /// in; otherwise returns immediately.
  static Future<void> maybeFullSync() async {
    if (!SupabaseService.isInitialized) return;
    if (SupabaseService.client.auth.currentUser == null) return;
    await instance.fullSync();
  }

  /// Syncs everything to and from the cloud, in this order:
  ///
  /// 1. **Profiles** first, so the cloud profile identities exist locally
  ///    before any profile-scoped data is pulled (cloud
  ///    `user_profiles.profile_id` equals the local profile id — see
  ///    [ProfileManager.localToCloudIdMap]). Pull before push so the
  ///    single-active-profile enforcement is driven by the CLOUD-flagged
  ///    active row, then push local edits.
  /// 2. **Playlists** — Pro-gated internally by [PlaylistSyncService].
  /// 3. **Favourites** — any signed-in user.
  /// 4. **Watch progress** — Pro-gated internally by
  ///    [WatchProgressService].
  ///
  /// Within each data service the pull runs before the push: pull merges
  /// cloud rows into local (newer-wins / restore), then push uploads the
  /// merged state and reconciles deletions — pushing first would make the
  /// deletion reconciliation consider not-yet-pulled cloud rows stale.
  /// All errors are logged and swallowed — sync must never disrupt the UI
  /// flow that triggered it.
  Future<void> fullSync() async {
    if (_syncing) return; // A sync is already in flight.
    _syncing = true;
    try {
      // Refresh the tier cache so the Pro-gated syncs can run.
      await _entitlementService.refreshTier();

      // 1. Profiles (not tier-gated).
      await ProfileManager.instance.syncFromCloud();
      await ProfileManager.instance.syncToCloud();

      // 2. Playlists (Pro).
      await PlaylistSyncService.instance.syncFromCloud();
      await PlaylistSyncService.instance.syncToCloud();

      // 3. Favourites (Free + Pro).
      await _favoritesService.syncFromCloud();
      await _favoritesService.syncToCloud();

      // 4. Watch progress (Pro).
      await _watchProgressService.syncFromCloud();
      await _watchProgressService.syncToCloud();
    } catch (e) {
      // ignore: avoid_print
      print('[SyncCoordinator] fullSync failed: $e');
    } finally {
      _syncing = false;
    }
  }
}
