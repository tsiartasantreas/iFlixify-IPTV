import 'package:supabase_flutter/supabase_flutter.dart';

import '../entitlement/entitlement_service.dart';
import 'encryption_service.dart';
import 'playlist_manager.dart';
import 'supabase_client.dart';

/// Syncs playlists (with their credentials) between the local Drift
/// database and the Supabase `playlists_sync` table for cross-device
/// backup — Pro only.
///
/// Credentials (URL, username, password) are ENCRYPTED client-side with
/// [EncryptionService] (AES-256-CBC, user-scoped key) before upload and
/// decrypted after download, so plaintext never reaches Supabase. Because
/// the encryption key is derived from the Supabase user ID, every device
/// signed in as the same user can decrypt the synced values.
///
/// All errors are logged and swallowed — sync must never disrupt the UI
/// flow that triggered it.
class PlaylistSyncService {
  PlaylistSyncService._();

  /// Shared singleton instance.
  static final PlaylistSyncService instance = PlaylistSyncService._();

  final PlaylistManager _playlistManager = PlaylistManager();
  final EntitlementService _entitlementService = EntitlementService();

  // ---------------------------------------------------------------------------
  // Cloud sync (Pro only)
  // ---------------------------------------------------------------------------

  /// Pushes all local playlists to the Supabase `playlists_sync` table.
  ///
  /// For each local playlist the stored credentials are decrypted and
  /// re-encrypted scoped to the signed-in user's ID (so anonymous-scope
  /// blobs become portable), then upserted keyed on
  /// `(user_id, playlist_id)` where `playlist_id` is the local playlist
  /// id as a string. Does nothing (silently) for free-tier users or when
  /// nobody is signed in.
  Future<void> syncToCloud() async {
    SupabaseClient? client;
    try {
      if (!await _entitlementService.canUseProFeatures) return;
      client = await _ensureClient();
      final userId = client?.auth.currentUser?.id;
      if (client == null || userId == null) return;

      final playlists = await _playlistManager.getPlaylists();
      if (playlists.isEmpty) return;

      final rows = playlists.map((p) {
        // Credentials are stored encrypted locally; decrypt, then
        // re-encrypt scoped to the signed-in user so every device that
        // signs in as this user can decrypt the cloud copy.
        final decryptedUsername = _playlistManager.getDecryptedUsername(p);
        final decryptedPassword = _playlistManager.getDecryptedPassword(p);
        return {
          'user_id': userId,
          // Playlists are not profile-scoped locally yet; profile_id 0 is
          // the shared/default bucket (see migration 00009).
          'profile_id': 0,
          'playlist_id': p.id.toString(),
          'name': p.name,
          'url': EncryptionService.encrypt(
            _playlistManager.getDecryptedUrl(p),
            userId: userId,
          ),
          'username': decryptedUsername == null
              ? null
              : EncryptionService.encrypt(decryptedUsername, userId: userId),
          'password': decryptedPassword == null
              ? null
              : EncryptionService.encrypt(decryptedPassword, userId: userId),
          'playlist_type': decryptedUsername != null ? 'xtream' : 'm3u',
          'updated_at': DateTime.now().toIso8601String(),
        };
      }).toList();

      await client
          .from('playlists_sync')
          .upsert(rows, onConflict: 'user_id,playlist_id');

      // Reconcile deletions: cloud playlists that no longer exist locally
      // (deleted on this device) are removed so [syncFromCloud] cannot
      // re-insert them. Safe because of the playlists.isEmpty early-return
      // above — a device with no local playlists can never wipe the cloud
      // copy — and because [fullSync] always pulls before pushing.
      final localIds = playlists.map((p) => p.id.toString()).toSet();
      final cloudRows = await client
          .from('playlists_sync')
          .select('playlist_id')
          .eq('user_id', userId);
      for (final row in cloudRows) {
        final cloudId = row['playlist_id'] as String?;
        if (cloudId == null || localIds.contains(cloudId)) continue;
        await client.from('playlists_sync').delete().match({
          'user_id': userId,
          'playlist_id': cloudId,
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('[PlaylistSyncService] syncToCloud failed: $e');
    }
  }

  /// Pulls cloud playlists into the local database (Pro only).
  ///
  /// Insert-only: any cloud playlist that does not already exist locally
  /// (matched by local playlist id, or by an identical credential URL to
  /// avoid cross-device duplicates) is inserted via [PlaylistManager].
  /// Local playlists are never overwritten or deleted, so local edits are
  /// preserved.
  Future<void> syncFromCloud() async {
    SupabaseClient? client;
    try {
      if (!await _entitlementService.canUseProFeatures) return;
      client = await _ensureClient();
      final userId = client?.auth.currentUser?.id;
      if (client == null || userId == null) return;

      final response = await client
          .from('playlists_sync')
          .select()
          .eq('user_id', userId);

      final localPlaylists = await _playlistManager.getPlaylists();
      final localIds = localPlaylists.map((p) => p.id.toString()).toSet();
      final localUrls = localPlaylists
          .map((p) => _playlistManager.getDecryptedUrl(p))
          .toSet();

      for (final row in response) {
        try {
          final cloudPlaylistId = row['playlist_id'] as String?;
          if (cloudPlaylistId == null) continue;

          final url = EncryptionService.decrypt(
            row['url'] as String,
            userId: userId,
          );

          // Skip playlists that already exist locally — insert-only, never
          // overwrite local edits.
          if (localIds.contains(cloudPlaylistId) || localUrls.contains(url)) {
            continue;
          }

          final rawName = row['name'] as String?;
          final name =
              (rawName != null && rawName.isNotEmpty) ? rawName : 'Playlist';
          final usernameCipher = (row['username'] as String?)?.trim();
          final passwordCipher = (row['password'] as String?)?.trim();

          await _playlistManager.addPlaylist(
            name,
            url,
            username: usernameCipher == null || usernameCipher.isEmpty
                ? null
                : EncryptionService.decrypt(usernameCipher, userId: userId),
            password: passwordCipher == null || passwordCipher.isEmpty
                ? null
                : EncryptionService.decrypt(passwordCipher, userId: userId),
          );
        } catch (e) {
          // A single bad row must not abort the rest of the pull.
          // ignore: avoid_print
          print('[PlaylistSyncService] syncFromCloud row skipped: $e');
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[PlaylistSyncService] syncFromCloud failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Lazily initializes Supabase and returns the client, or `null` when
  /// initialization is impossible (e.g. missing configuration).
  Future<SupabaseClient?> _ensureClient() async {
    if (!SupabaseService.isInitialized) {
      try {
        await SupabaseService.initialize();
      } catch (_) {
        return null;
      }
    }
    return SupabaseService.isInitialized ? SupabaseService.client : null;
  }
}
