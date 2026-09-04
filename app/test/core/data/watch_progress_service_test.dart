import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iflixify/core/data/database.dart';
import 'package:iflixify/core/data/watch_progress_service.dart';
import 'package:iflixify/core/entitlement/entitlement_service.dart';

void main() {
  late AppDatabase db;
  late WatchProgressService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = WatchProgressService(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  // ---------------------------------------------------------------------------
  // Helper to seed content tables for episode / Up Next tests
  // ---------------------------------------------------------------------------

  Future<void> seedSeries({
    int seriesId = 1,
    String seriesTitle = 'Breaking Bad',
    int playlistId = 1,
  }) async {
    await db
        .into(db.playlists)
        .insert(PlaylistsCompanion.insert(name: 'test', url: 'x', type: 'm3u'));
    await db.into(db.tvSeries).insert(
          TvSeriesCompanion.insert(
            playlistId: playlistId,
            title: seriesTitle,
          ),
        );
  }

  Future<void> seedEpisodes(int seriesId, {int count = 3}) async {
    for (var i = 1; i <= count; i++) {
      await db.into(db.episodes).insert(
            EpisodesCompanion.insert(
              seriesId: seriesId,
              season: 1,
              episode: i,
              title: 'Episode $i',
              url: 'http://example.com/ep$i.m3u8',
            ),
          );
    }
  }

  // ===========================================================================
  // saveProgress
  // ===========================================================================

  group('saveProgress', () {
    test('inserts a new progress entry', () async {
      await service.saveProgress('vod:1', 5000, 60000);

      final entry = await service.getProgress('vod:1');
      expect(entry, isNotNull);
      // Stored under the profile-scoped id ('default' profile in tests).
      expect(entry!.contentId, 'default:vod:1');
      expect(entry.positionMs, 5000);
      expect(entry.durationMs, 60000);
    });

    test('updates an existing progress entry', () async {
      await service.saveProgress('vod:1', 5000, 60000);
      await service.saveProgress('vod:1', 10000, 60000);

      final entry = await service.getProgress('vod:1');
      expect(entry!.positionMs, 10000);
    });

    test('clears progress when >= 95% watched (completed)', () async {
      await service.saveProgress('vod:1', 57000, 60000); // 95%
      final entry = await service.getProgress('vod:1');
      expect(entry, isNull);
    });

    test('clears progress when 100% watched', () async {
      await service.saveProgress('vod:1', 60000, 60000);
      final entry = await service.getProgress('vod:1');
      expect(entry, isNull);
    });

    test('does not save when durationMs is zero', () async {
      await service.saveProgress('vod:1', 0, 0);
      final entry = await service.getProgress('vod:1');
      expect(entry, isNull);
    });

    test('does not save when durationMs is negative', () async {
      await service.saveProgress('vod:1', 100, -1);
      final entry = await service.getProgress('vod:1');
      expect(entry, isNull);
    });

    test('saves progress just below 95% threshold', () async {
      // 94.9% should still be saved.
      final pos = (60000 * 0.949).toInt(); // 56940
      await service.saveProgress('vod:1', pos, 60000);
      final entry = await service.getProgress('vod:1');
      expect(entry, isNotNull);
      expect(entry!.positionMs, pos);
    });
  });

  // ===========================================================================
  // getProgress
  // ===========================================================================

  group('getProgress', () {
    test('returns null when no progress exists', () async {
      final entry = await service.getProgress('vod:999');
      expect(entry, isNull);
    });

    test('returns the correct entry', () async {
      await service.saveProgress('live:5', 1234, 9999);
      final entry = await service.getProgress('live:5');
      expect(entry, isNotNull);
      // Stored under the profile-scoped id ('default' profile in tests).
      expect(entry!.contentId, 'default:live:5');
      expect(entry.positionMs, 1234);
      expect(entry.durationMs, 9999);
    });
  });

  // ===========================================================================
  // clearProgress
  // ===========================================================================

  group('clearProgress', () {
    test('removes an existing entry', () async {
      await service.saveProgress('vod:1', 5000, 60000);
      expect(await service.getProgress('vod:1'), isNotNull);

      await service.clearProgress('vod:1');
      expect(await service.getProgress('vod:1'), isNull);
    });

    test('is a no-op for non-existent content', () async {
      // Should not throw.
      await service.clearProgress('vod:999');
      expect(await service.getProgress('vod:999'), isNull);
    });
  });

  // ===========================================================================
  // getContinueWatching
  // ===========================================================================

  group('getContinueWatching', () {
    test('returns empty list when no progress exists', () async {
      final items = await service.getContinueWatching();
      expect(items, isEmpty);
    });

    test('returns items sorted by most recently updated', () async {
      final now = DateTime.now();
      // Insert directly with explicit timestamps to guarantee ordering.
      await db.into(db.watchProgressEntry).insert(
            WatchProgressEntryCompanion(
              contentId: const Value('vod:1'),
              positionMs: const Value(6000),
              durationMs: const Value(60000),
              updatedAt: Value(now.subtract(const Duration(hours: 2))),
            ),
          );
      await db.into(db.watchProgressEntry).insert(
            WatchProgressEntryCompanion(
              contentId: const Value('vod:2'),
              positionMs: const Value(12000),
              durationMs: const Value(60000),
              updatedAt: Value(now.subtract(const Duration(hours: 1))),
            ),
          );
      await db.into(db.watchProgressEntry).insert(
            WatchProgressEntryCompanion(
              contentId: const Value('vod:3'),
              positionMs: const Value(18000),
              durationMs: const Value(60000),
              updatedAt: Value(now),
            ),
          );

      final items = await service.getContinueWatching();
      expect(items.length, 3);
      // Most recent first.
      expect(items[0].contentId, 'vod:3');
      expect(items[1].contentId, 'vod:2');
      expect(items[2].contentId, 'vod:1');
    });

    test('respects limit parameter', () async {
      for (var i = 1; i <= 15; i++) {
        await service.saveProgress('vod:$i', 6000, 60000); // 10%
      }

      final items = await service.getContinueWatching(limit: 5);
      expect(items.length, 5);
    });

    test('includes barely-started items (any progress > 0)', () async {
      // 1% progress -- now included (floor is fraction > 0, not >= 5%).
      await service.saveProgress('vod:1', 600, 60000);
      // 10% progress -- also included.
      await service.saveProgress('vod:2', 6000, 60000);

      final items = await service.getContinueWatching();
      expect(items.length, 2);
      final contentIds = items.map((i) => i.contentId).toSet();
      expect(contentIds, containsAll(['default:vod:1', 'default:vod:2']));
    });

    test('includes items at exactly 5% progress', () async {
      await service.saveProgress('vod:1', 3000, 60000); // 5%
      final items = await service.getContinueWatching();
      expect(items.length, 1);
    });

    test('excludes completed items (cleared by saveProgress)', () async {
      await service.saveProgress('vod:1', 5000, 60000);
      // Mark as completed (>= 95%).
      await service.saveProgress('vod:1', 57000, 60000);

      final items = await service.getContinueWatching();
      expect(items, isEmpty);
    });

    test('works across different content types', () async {
      await service.saveProgress('live:1', 5000, 60000);
      await service.saveProgress('vod:2', 10000, 60000);
      await service.saveProgress('episode:3', 15000, 60000);

      final items = await service.getContinueWatching();
      expect(items.length, 3);

      // Rows are stored under the profile-scoped id ('default' in tests) and
      // getContinueWatching returns the stored (scoped) contentId.
      final contentIds = items.map((i) => i.contentId).toSet();
      expect(
        contentIds,
        containsAll(['default:live:1', 'default:vod:2', 'default:episode:3']),
      );
    });
  });

  // ===========================================================================
  // getUpNext
  // ===========================================================================

  group('getUpNext', () {
    setUp(() async {
      await seedSeries(seriesId: 1);
      await seedEpisodes(1, count: 3);
    });

    test('returns the next episode in the same season', () async {
      final upNext = await service.getUpNext('episode:1');
      expect(upNext, isNotNull);
      expect(upNext!.episodeId, 2);
      expect(upNext.season, 1);
      expect(upNext.episode, 2);
      expect(upNext.title, 'Episode 2');
      expect(upNext.seriesTitle, 'Breaking Bad');
    });

    test('returns null when on the last episode', () async {
      final upNext = await service.getUpNext('episode:3');
      expect(upNext, isNull);
    });

    test('returns null for non-episode contentId', () async {
      final upNext = await service.getUpNext('vod:1');
      expect(upNext, isNull);
    });

    test('returns null for malformed contentId', () async {
      final upNext = await service.getUpNext('invalid');
      expect(upNext, isNull);
    });

    test('returns null for non-existent episode', () async {
      final upNext = await service.getUpNext('episode:999');
      expect(upNext, isNull);
    });

    test('label is formatted correctly', () async {
      final upNext = await service.getUpNext('episode:1');
      expect(upNext!.label, 'S1:E2 - Episode 2');
    });

    test('contentId is formatted correctly', () async {
      final upNext = await service.getUpNext('episode:1');
      expect(upNext!.contentId, 'episode:2');
    });

    test('returns null when no next episode in series', () async {
      // Create a series with only one episode.
      await db.into(db.tvSeries).insert(
            TvSeriesCompanion.insert(
              playlistId: 1,
              title: 'Short Series',
            ),
          );
      await db.into(db.episodes).insert(
            EpisodesCompanion.insert(
              seriesId: 2,
              season: 1,
              episode: 1,
              title: 'Only Episode',
              url: 'http://example.com/only.m3u8',
            ),
          );
      final upNext = await service.getUpNext('episode:4');
      expect(upNext, isNull); // Only one episode, no "next".
    });
  });

  // ===========================================================================
  // syncToCloud / syncFromCloud -- free-tier no-ops
  // ===========================================================================

  group('cloud sync (free tier)', () {
    test('syncToCloud is a no-op when entitlement is free', () async {
      // EntitlementService with no user => isPro is false.
      final freeService = WatchProgressService(
        database: db,
        entitlementService: EntitlementService(),
      );
      await freeService.saveProgress('vod:1', 5000, 60000);
      // Should not throw even without a Supabase client.
      await freeService.syncToCloud();
    });

    test('syncFromCloud is a no-op when entitlement is free', () async {
      final freeService = WatchProgressService(
        database: db,
        entitlementService: EntitlementService(),
      );
      // Should not throw even without a Supabase client.
      await freeService.syncFromCloud();
    });
  });

  // ===========================================================================
  // EpisodeUpNext data class
  // ===========================================================================

  group('EpisodeUpNext', () {
    test('label formats season and episode correctly', () {
      const ep = EpisodeUpNext(
        episodeId: 1,
        seriesId: 1,
        seriesTitle: 'Test',
        season: 2,
        episode: 5,
        title: 'Pilot',
        url: 'http://example.com',
      );
      expect(ep.label, 'S2:E5 - Pilot');
    });

    test('contentId uses episode prefix', () {
      const ep = EpisodeUpNext(
        episodeId: 42,
        seriesId: 1,
        seriesTitle: 'Test',
        season: 1,
        episode: 1,
        title: 'First',
        url: 'http://example.com',
      );
      expect(ep.contentId, 'episode:42');
    });

    test('thumbnail can be null', () {
      const ep = EpisodeUpNext(
        episodeId: 1,
        seriesId: 1,
        seriesTitle: 'Test',
        season: 1,
        episode: 1,
        title: 'First',
        url: 'http://example.com',
      );
      expect(ep.thumbnail, isNull);
    });
  });
}
