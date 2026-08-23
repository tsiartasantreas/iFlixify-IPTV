import 'dart:io';

import 'package:url_launcher/url_launcher.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/data/database.dart';
import '../../core/data/offline_download_service.dart';
import '../../core/data/playlist_manager.dart';
import '../../core/data/watch_progress_service.dart';
import '../../core/data/xtream_api_client.dart';
import '../../core/player/player_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/favorite_button.dart';
import '../player/player_screen.dart';
import '../player/tv_player_screen.dart';
import 'widgets/download_button.dart';
import 'widgets/episode_download_button.dart';

/// Content detail screen showing title, poster, and play button.
///
/// Supports live channels, VOD, series (with episodes), and radio.
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.id,
    required this.title,
    this.imageUrl,
    required this.url,
    this.groupTitle,
    required this.contentType,
  });

  final int id;
  final String title;
  final String? imageUrl;
  final String url;
  final String? groupTitle;
  final String contentType;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final _db = AppDatabase();
  final _downloadService = OfflineDownloadService.instance;
  late final _watchService = WatchProgressService(database: _db);
  List<_EpisodeItem> _episodes = [];
  bool _isLoadingEpisodes = false;
  EpgProgramme? _currentProgramme;
  EpgProgramme? _nextProgramme;

  // Metadata loaded from database for VOD / Series.
  VodItem? _vodItem;
  TvSery? _seriesData;

  bool get _isTv =>
      Platform.isLinux ||
      (Platform.isAndroid &&
          MediaQueryData.fromView(
                      WidgetsBinding.instance.platformDispatcher.views.first)
                  .size
                  .shortestSide >
              960);

  bool get _isLive => widget.contentType == 'live';
  bool get _isSeries => widget.contentType == 'series';

  bool get _isVod => widget.contentType == 'vod';

  @override
  void initState() {
    super.initState();
    if (_isSeries) {
      _loadSeriesMetadata();
      _loadEpisodes();
    }
    if (_isVod) {
      _loadVodMetadata();
    }
    if (_isLive) {
      _loadEpgData();
    }
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadEpisodes() async {
    setState(() => _isLoadingEpisodes = true);

    try {
      final episodes = await (_db.select(_db.episodes)
            ..where((t) => t.seriesId.equals(widget.id))
            ..orderBy([
              (t) => drift.OrderingTerm.asc(t.season),
              (t) => drift.OrderingTerm.asc(t.episode),
            ]))
          .get();

      if (mounted) {
        setState(() {
          _episodes = episodes
              .map((ep) => _EpisodeItem(
                    id: ep.id,
                    season: ep.season,
                    episode: ep.episode,
                    title: ep.title,
                    url: ep.url,
                    thumbnail: ep.thumbnail,
                  ))
              .toList();
          _isLoadingEpisodes = false;
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('[DetailScreen] Failed to load episodes: $e');
      if (mounted) {
        setState(() {
          _episodes = [];
          _isLoadingEpisodes = false;
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // EPG data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadEpgData() async {
    try {
      // Look up the channel's tvgName for EPG matching.
      final channel = await (_db.select(_db.channels)
            ..where((t) => t.id.equals(widget.id)))
          .getSingleOrNull();
      if (channel == null) return;

      // Build list of possible EPG channel IDs to match.
      final matchIds = <String>[];
      if (channel.tvgName != null && channel.tvgName!.isNotEmpty) {
        matchIds.add(channel.tvgName!);
      }
      matchIds.add(channel.name);

      final now = DateTime.now();

      // Query all programmes for matching channel IDs, ordered by start.
      final programmes = await (_db.select(_db.epgProgrammes)
            ..where((t) => t.channelId.isIn(matchIds))
            ..orderBy([(t) => drift.OrderingTerm.asc(t.start)]))
          .get();

      if (programmes.isEmpty) return;

      // Find the current programme (start <= now < stop).
      EpgProgramme? current;
      EpgProgramme? next;
      for (final p in programmes) {
        if (p.start.isBefore(now) && p.stop.isAfter(now)) {
          current = p;
        } else if (p.start.isAfter(now) && current != null) {
          next = p;
          break;
        }
      }

      // If we found current but not next, look for the programme right after.
      if (current != null && next == null) {
        for (final p in programmes) {
          if (p.start.isAfter(current.stop)) {
            next = p;
            break;
          }
        }
      }

      // If no current programme found, find the next upcoming one.
      if (current == null) {
        for (final p in programmes) {
          if (p.start.isAfter(now)) {
            next = p;
            break;
          }
        }
      }

      if (mounted) {
        setState(() {
          _currentProgramme = current;
          _nextProgramme = next;
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('[DetailScreen] Failed to load EPG data: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // VOD metadata loading
  // ---------------------------------------------------------------------------

  Future<void> _loadVodMetadata() async {
    try {
      final item = await (_db.select(_db.vodItems)
            ..where((t) => t.id.equals(widget.id)))
          .getSingleOrNull();
      if (mounted && item != null) {
        setState(() => _vodItem = item);
        // If description is empty, try fetching detailed info from the API.
        if (item.description == null || item.description!.isEmpty) {
          _fetchVodDetailFromApi(item);
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[DetailScreen] Failed to load VOD metadata: $e');
    }
  }

  /// Fetch detailed VOD info from the Xtream API and update the database.
  Future<void> _fetchVodDetailFromApi(VodItem item) async {
    try {
      // Extract streamId from the URL (format: .../movie/user/pass/STREAM_ID.ext)
      final uri = Uri.parse(item.url);
      final segments = uri.pathSegments;
      if (segments.length < 2) return;
      final idStr = segments.last.split('.').first;
      final streamId = int.tryParse(idStr);
      if (streamId == null || streamId == 0) return;

      // Initialize Xtream client
      final playlists = await (_db.select(_db.playlists)).get();
      if (playlists.isEmpty) return;

      // Find the playlist for this item
      final playlist = playlists.firstWhere(
        (p) => p.id == item.playlistId,
        orElse: () => playlists.first,
      );

      // Decrypt credentials
      final pm = PlaylistManager(database: _db);
      final baseUrl = pm.getDecryptedUrl(playlist);
      final username = pm.getDecryptedUsername(playlist);
      final password = pm.getDecryptedPassword(playlist);
      if (username == null || password == null) return;

      final client = XtreamApiClient(
        baseUrl: baseUrl,
        username: username,
        password: password,
      );

      // ignore: avoid_print
      print('[DetailScreen] Fetching VOD detail for streamId=$streamId');
      final info = await client.getVodInfo(streamId);
      client.close();

      if (mounted) {
        setState(() {
          _vodItem = VodItem(
            id: item.id,
            playlistId: item.playlistId,
            title: item.title,
            poster: item.poster,
            url: item.url,
            groupTitle: item.groupTitle,
            description: info['plot'] as String? ?? item.description,
            rating: (info['rating'] as String?) ?? item.rating,
            genre: info['genre'] as String? ?? item.genre,
            cast: info['cast'] as String? ?? item.cast,
            director: info['director'] as String? ?? item.director,
            releaseDate: info['releasedate'] as String? ?? item.releaseDate,
          );
        });

        // Update the database with the fetched metadata.
        await (_db.update(_db.vodItems)
              ..where((t) => t.id.equals(item.id)))
            .write(VodItemsCompanion(
          description: drift.Value(_vodItem!.description),
          rating: drift.Value(_vodItem!.rating),
          genre: drift.Value(_vodItem!.genre),
          cast: drift.Value(_vodItem!.cast),
          director: drift.Value(_vodItem!.director),
          releaseDate: drift.Value(_vodItem!.releaseDate),
        ));
      }
    } catch (e) {
      // ignore: avoid_print
      print('[DetailScreen] Failed to fetch VOD detail from API: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Series metadata loading
  // ---------------------------------------------------------------------------

  Future<void> _loadSeriesMetadata() async {
    try {
      final series = await (_db.select(_db.tvSeries)
            ..where((t) => t.id.equals(widget.id)))
          .getSingleOrNull();
      if (mounted && series != null) {
        setState(() => _seriesData = series);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[DetailScreen] Failed to load series metadata: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Channel navigation (live TV — next/prev in same group)
  // ---------------------------------------------------------------------------

  /// Cache of channels in the same group as the current live channel, ordered
  /// by name.  Loaded lazily on first play of a live channel.
  List<Channel>? _siblingChannels;
  int _currentChannelIndex = -1;

  /// Load channels in the same group as the current channel, determine the
  /// current channel's index, and cache the result.
  Future<void> _ensureSiblingChannels() async {
    if (_siblingChannels != null) return;
    if (widget.groupTitle == null || widget.groupTitle!.isEmpty) return;

    try {
      // First get the current channel to find its playlistId.
      final currentChannel = await (_db.select(_db.channels)
            ..where((t) => t.id.equals(widget.id)))
          .getSingleOrNull();
      if (currentChannel == null) return;

      // Get all channels in the same group from the same playlist.
      final channels = await (_db.select(_db.channels)
            ..where((t) =>
                t.playlistId.equals(currentChannel.playlistId) &
                t.groupTitle.equals(widget.groupTitle!))
            ..orderBy([(t) => drift.OrderingTerm.asc(t.name)]))
          .get();

      _siblingChannels = channels;
      _currentChannelIndex =
          channels.indexWhere((c) => c.id == widget.id);
    } catch (e) {
      // ignore: avoid_print
      print('[DetailScreen] Failed to load sibling channels: $e');
      _siblingChannels = [];
    }
  }

  void _playNextChannel() {
    if (_siblingChannels == null || _siblingChannels!.isEmpty) return;
    final nextIndex = _currentChannelIndex + 1;
    if (nextIndex >= _siblingChannels!.length) return; // Already last.
    final next = _siblingChannels![nextIndex];
    _currentChannelIndex = nextIndex;
    // Pop the current player and play the next channel.
    Navigator.of(context).pop();
    _playContent(next.url, next.name, isLive: true);
  }

  void _playPreviousChannel() {
    if (_siblingChannels == null || _siblingChannels!.isEmpty) return;
    final prevIndex = _currentChannelIndex - 1;
    if (prevIndex < 0) return; // Already first.
    final prev = _siblingChannels![prevIndex];
    _currentChannelIndex = prevIndex;
    Navigator.of(context).pop();
    _playContent(prev.url, prev.name, isLive: true);
  }

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  Future<void> _playContent(
    String url,
    String title, {
    bool isLive = false,
    String? contentId,
    String? watchContentId,
  }) async {
    // ignore: avoid_print
    print('[DetailScreen] Playing: title="$title", url=$url, isLive=$isLive, contentType=${widget.contentType}');

    // If a contentId is provided, check for a local download first.
    String playbackUrl = url;
    if (contentId != null) {
      final localPath = await _downloadService.getLocalPath(contentId);
      if (localPath != null && await File(localPath).exists()) {
        playbackUrl = localPath;
      }
    }

    // Look up saved watch progress so playback can resume where the user
    // left off (only for non-live content with a valid watch key).
    Duration? startPosition;
    if (!isLive && watchContentId != null && watchContentId.isNotEmpty) {
      try {
        final progress = await _watchService.getProgress(watchContentId);
        if (progress != null &&
            progress.positionMs > 30000 &&
            progress.durationMs > 0 &&
            progress.positionMs < progress.durationMs * 0.95) {
          startPosition = Duration(milliseconds: progress.positionMs);
        }
      } catch (e) {
        // ignore: avoid_print
        print('[DetailScreen] Failed to load watch progress: $e');
      }
    }

    // ignore: avoid_print
    print('[DetailScreen] Resolved playback URL: $playbackUrl');

    // Check if external player is preferred.
    final prefs = await SharedPreferences.getInstance();
    final useExternalPlayer = prefs.getBool('use_external_player') ?? false;

    if (useExternalPlayer) {
      await _launchExternalPlayer(playbackUrl);
      return;
    }

    if (!mounted) return;

    // For live TV, pre-load sibling channels for next/prev navigation.
    VoidCallback? onNext;
    VoidCallback? onPrevious;
    if (isLive) {
      await _ensureSiblingChannels();
      if (_siblingChannels != null && _siblingChannels!.isNotEmpty) {
        if (_currentChannelIndex < _siblingChannels!.length - 1) {
          onNext = _playNextChannel;
        }
        if (_currentChannelIndex > 0) {
          onPrevious = _playPreviousChannel;
        }
      }
    }

    if (!mounted) return;

    final controller = PlayerController();
    controller.open(playbackUrl);

    final playerScreen = _isTv
        ? TvPlayerScreen(
            controller: controller,
            title: title,
            isLive: isLive,
            category: widget.groupTitle,
            contentType: widget.contentType,
            onNextChannel: onNext,
            onPreviousChannel: onPrevious,
            contentId: watchContentId,
            startPosition: startPosition,
            poster: widget.imageUrl,
            url: widget.url,
          )
        : PlayerScreen(
            controller: controller,
            title: title,
            isLive: isLive,
            category: widget.groupTitle,
            contentType: widget.contentType,
            onNextChannel: onNext,
            onPreviousChannel: onPrevious,
            contentId: watchContentId,
            startPosition: startPosition,
            poster: widget.imageUrl,
            url: widget.url,
          );

    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => playerScreen))
        .then((_) => controller.dispose());
  }

  // ---------------------------------------------------------------------------
  // External player launch
  // ---------------------------------------------------------------------------

  /// Opens [playbackUrl] in an external video player (e.g. VLC, MX Player).
  ///
  /// Uses `externalApplication` so Android shows the app chooser for video
  /// players instead of the browser. Skips `canLaunchUrl` which is unreliable
  /// on Android 11+ (returns false for apps that haven't declared intent
  /// filters for the URL scheme).
  Future<void> _launchExternalPlayer(String playbackUrl) async {
    final uri = Uri.parse(playbackUrl);

    // Launch directly — Android's intent resolution will show the app
    // chooser if multiple video players are installed (VLC, MX Player, etc.).
    // No canLaunchUrl check: it returns false on Android 11+ for non-browser
    // apps due to package visibility rules.
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return;
    } catch (e) {
      // ignore: avoid_print
      print('[DetailScreen] External application launch failed: $e');
    }

    // Nothing worked
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Failed to open external player. Install VLC or MX Player.'),
          backgroundColor: AppColors.bgSurface,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      body: CustomScrollView(
        slivers: [
          // -- App bar with poster background -------------------------------
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            backgroundColor: AppColors.bgElevated,
            iconTheme: const IconThemeData(color: AppColors.textPrimary),
            flexibleSpace: FlexibleSpaceBar(
              background: widget.imageUrl != null &&
                      widget.imageUrl!.isNotEmpty
                  ? Image.network(
                      widget.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _buildPosterPlaceholder(),
                    )
                  : _buildPosterPlaceholder(),
            ),
          ),

          // -- Content details ---------------------------------------------
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FocusTraversalGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // -- Title -----------------------------------------------
                    Text(
                      widget.title,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // -- Group tag -------------------------------------------
                    if (widget.groupTitle != null &&
                        widget.groupTitle!.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.bgSurface,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          widget.groupTitle!,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),

                    // -- Content type badge ----------------------------------
                    _buildTypeBadge(),
                    const SizedBox(height: 16),

                    // -- Info badges (genre, rating, duration, year) -----------
                    if (_isVod || _isSeries) ...[
                      _buildInfoBadges(),
                      const SizedBox(height: 16),
                    ],

                    // -- Description / Plot ------------------------------------
                    if (_descriptionText != null &&
                        _descriptionText!.isNotEmpty) ...[
                      Text(
                        _descriptionText!,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // -- Cast & Director ---------------------------------------
                    if (_castText != null || _directorText != null) ...[
                      _buildCastDirectorSection(),
                      const SizedBox(height: 16),
                    ],

                    // -- Additional Info (country, release date, etc.) ---------
                    if (_isVod || _isSeries) ...[
                      _buildAdditionalInfoSection(),
                      const SizedBox(height: 20),
                    ],

                    // -- Play + Download + Favorite buttons ----------------------
                    if (widget.url.isNotEmpty)
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: Focus(
                                onKeyEvent: (node, event) {
                                  if (event is KeyDownEvent &&
                                      event.logicalKey ==
                                          LogicalKeyboardKey.select) {
                                    _playContent(
                                      widget.url,
                                      widget.title,
                                      isLive: _isLive,
                                      contentId:
                                          '${widget.contentType}_${widget.id}',
                                      watchContentId:
                                          '${widget.contentType}:${widget.id}',
                                    );
                                    return KeyEventResult.handled;
                                  }
                                  return KeyEventResult.ignored;
                                },
                                child: ElevatedButton.icon(
                                  onPressed: () => _playContent(
                                    widget.url,
                                    widget.title,
                                    isLive: _isLive,
                                    contentId:
                                        '${widget.contentType}_${widget.id}',
                                    watchContentId:
                                        '${widget.contentType}:${widget.id}',
                                  ),
                                  icon: const Icon(Icons.play_arrow, size: 24),
                                  label: Text(
                                    _isLive ? 'Watch Live' : 'Play',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
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
                            ),
                          ),
                          const SizedBox(width: 12),
                          FavoriteButton(
                            contentId:
                                '${widget.contentType}:${widget.id}',
                            contentType: widget.contentType,
                            title: widget.title,
                            poster: widget.imageUrl,
                            url: widget.url,
                            size: 28,
                          ),
                          if (!_isLive) ...[
                            const SizedBox(width: 12),
                            DownloadButton(
                              contentId: '${widget.contentType}_${widget.id}',
                              title: widget.title,
                              url: widget.url,
                              contentType: widget.contentType,
                              thumbnailUrl: widget.imageUrl,
                              onPlayOffline: () => _playContent(
                                widget.url,
                                widget.title,
                                isLive: _isLive,
                                contentId:
                                    '${widget.contentType}_${widget.id}',
                                watchContentId:
                                    '${widget.contentType}:${widget.id}',
                              ),
                            ),
                          ],
                        ],
                      ),

                    // -- EPG Programme Guide (live channels) -----------------
                    if (_isLive &&
                        (_currentProgramme != null ||
                            _nextProgramme != null)) ...[
                      const SizedBox(height: 24),
                      const Text(
                        'Programme Guide',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_currentProgramme != null)
                        _buildEpgTile(
                          _currentProgramme!,
                          isLive: true,
                        ),
                      if (_nextProgramme != null) ...[
                        const SizedBox(height: 8),
                        _buildEpgTile(
                          _nextProgramme!,
                          isLive: false,
                        ),
                      ],
                    ],

                    // -- Series episodes -------------------------------------
                    if (_isSeries) ...[
                      const SizedBox(height: 32),
                      const Text(
                        'Episodes',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_isLoadingEpisodes)
                        const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.accentPrimary,
                          ),
                        )
                      else if (_episodes.isEmpty)
                        const Text(
                          'No episodes available.',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                          ),
                        )
                      else
                        ..._buildSeasonGroups(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Metadata helpers
  // ---------------------------------------------------------------------------

  String? get _descriptionText {
    if (_isVod) return _vodItem?.description;
    if (_isSeries) return _seriesData?.description;
    return null;
  }

  String? get _ratingText {
    if (_isVod) return _vodItem?.rating;
    if (_isSeries) return _seriesData?.rating;
    return null;
  }

  String? get _genreText {
    if (_isVod) return _vodItem?.genre;
    if (_isSeries) return _seriesData?.genre;
    return null;
  }

  String? get _castText {
    if (_isVod) return _vodItem?.cast;
    if (_isSeries) return _seriesData?.cast;
    return null;
  }

  String? get _directorText {
    if (_isVod) return _vodItem?.director;
    if (_isSeries) return _seriesData?.director;
    return null;
  }

  String? get _releaseDateText {
    if (_isVod) return _vodItem?.releaseDate;
    if (_isSeries) return _seriesData?.releaseDate;
    return null;
  }

  String? get _durationText => null;

  String? get _countryText => null;

  String? get _youtubeTrailer => null;

  String? get _episodeRunTime => null;

  /// Extract a year from a date string like "2024-01-15" or return null.
  String? _extractYear(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;
    final match = RegExp(r'^(\d{4})').firstMatch(dateStr);
    return match?.group(1);
  }

  // ---------------------------------------------------------------------------
  // Info badges
  // ---------------------------------------------------------------------------

  Widget _buildInfoBadges() {
    final badges = <Widget>[];

    // Genre
    if (_genreText != null && _genreText!.isNotEmpty) {
      badges.add(_buildBadge(Icons.category, _genreText!));
    }

    // Rating
    if (_ratingText != null && _ratingText!.isNotEmpty) {
      badges.add(_buildBadge(Icons.star, _ratingText!));
    }

    // Duration (VOD)
    if (_durationText != null && _durationText!.isNotEmpty) {
      badges.add(_buildBadge(Icons.access_time, _durationText!));
    }

    // Episode run time (Series)
    if (_episodeRunTime != null && _episodeRunTime!.isNotEmpty) {
      badges.add(_buildBadge(Icons.timer, '$_episodeRunTime min/ep'));
    }

    // Year
    final year = _extractYear(_releaseDateText);
    if (year != null) {
      badges.add(_buildBadge(Icons.calendar_today, year));
    }

    if (badges.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: badges,
    );
  }

  Widget _buildBadge(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 14),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Cast & Director section
  // ---------------------------------------------------------------------------

  Widget _buildCastDirectorSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_directorText != null && _directorText!.isNotEmpty) ...[
          const Text(
            'Director',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _directorText!,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
        if (_castText != null && _castText!.isNotEmpty) ...[
          if (_directorText != null && _directorText!.isNotEmpty)
            const SizedBox(height: 12),
          const Text(
            'Cast',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _castText!,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Additional info section
  // ---------------------------------------------------------------------------

  Widget _buildAdditionalInfoSection() {
    final rows = <_InfoRow>[];

    if (_countryText != null && _countryText!.isNotEmpty) {
      rows.add(_InfoRow(Icons.public, 'Country', _countryText!));
    }
    if (_releaseDateText != null && _releaseDateText!.isNotEmpty) {
      rows.add(_InfoRow(Icons.event, 'Release Date', _releaseDateText!));
    }
    if (_ratingText != null && _ratingText!.isNotEmpty) {
      rows.add(_InfoRow(Icons.rate_review, 'Rating', _ratingText!));
    }

    // YouTube trailer
    if (_youtubeTrailer != null && _youtubeTrailer!.isNotEmpty) {
      rows.add(const _InfoRow(Icons.ondemand_video, 'Trailer', 'Available'));
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Details',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        ...rows.map((row) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(row.icon, color: AppColors.textSecondary, size: 16),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 100,
                    child: Text(
                      row.label,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.value,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            )),
        // Trailer button
        if (_youtubeTrailer != null && _youtubeTrailer!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: () => _launchTrailer(_youtubeTrailer!),
              icon: const Icon(Icons.play_circle_outline,
                  color: AppColors.accentPrimary, size: 18),
              label: const Text(
                'Watch Trailer',
                style: TextStyle(
                  color: AppColors.accentPrimary,
                  fontSize: 13,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.accentPrimary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _launchTrailer(String trailer) async {
    // trailer can be a YouTube video ID or a full URL.
    String url;
    if (trailer.startsWith('http')) {
      url = trailer;
    } else {
      url = 'https://www.youtube.com/watch?v=$trailer';
    }
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      // ignore: avoid_print
      print('[DetailScreen] Failed to launch trailer: $e');
    }
  }

  Widget _buildTypeBadge() {
    IconData icon;
    String label;
    Color color;

    switch (widget.contentType) {
      case 'live':
        icon = Icons.live_tv;
        label = 'Live TV';
        color = Colors.red;
        break;
      case 'vod':
        icon = Icons.movie;
        label = 'Movie';
        color = AppColors.accentPrimary;
        break;
      case 'series':
        icon = Icons.tv;
        label = 'Series';
        color = Colors.blue;
        break;
      case 'radio':
        icon = Icons.radio;
        label = 'Radio';
        color = Colors.green;
        break;
      default:
        icon = Icons.help_outline;
        label = 'Unknown';
        color = AppColors.textSecondary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Season grouping
  // ---------------------------------------------------------------------------

  List<Widget> _buildSeasonGroups() {
    // Group episodes by season number.
    final seasonMap = <int, List<_EpisodeItem>>{};
    for (final ep in _episodes) {
      seasonMap.putIfAbsent(ep.season, () => []).add(ep);
    }
    final seasons = seasonMap.keys.toList()..sort();

    final widgets = <Widget>[];
    for (final season in seasons) {
      final eps = seasonMap[season]!;
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            'Season $season',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
      widgets.addAll(eps.map(_buildEpisodeTile));
    }
    return widgets;
  }

  // ---------------------------------------------------------------------------
  // Episode tile
  // ---------------------------------------------------------------------------

  Widget _buildEpisodeTile(_EpisodeItem episode) {
    final episodeContentId = 'series_ep_${episode.id}';
    return Card(
      color: AppColors.bgElevated,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.select) {
            _playContent(
              episode.url,
              episode.title,
              contentId: episodeContentId,
              watchContentId: 'episode:${episode.id}',
            );
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // -- Thumbnail -------------------------------------------------
              Container(
                width: 80,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.bgSurface,
                  borderRadius: BorderRadius.circular(4),
                ),
                clipBehavior: Clip.antiAlias,
                child:
                    episode.thumbnail != null && episode.thumbnail!.isNotEmpty
                        ? Image.network(
                            episode.thumbnail!,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(
                              Icons.movie,
                              color: AppColors.textSecondary,
                              size: 24,
                            ),
                          )
                        : const Icon(
                            Icons.movie,
                            color: AppColors.textSecondary,
                            size: 24,
                          ),
              ),
              const SizedBox(width: 12),

              // -- Info -------------------------------------------------------
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Episode number + title
                    Text(
                      'E${episode.episode} - ${episode.title}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // -- Actions ----------------------------------------------------
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EpisodeDownloadButton(
                    contentId: episodeContentId,
                    title:
                        'S${episode.season}E${episode.episode} - ${episode.title}',
                    url: episode.url,
                    thumbnailUrl: episode.thumbnail,
                    onPlayOffline: () => _playContent(
                      episode.url,
                      episode.title,
                      contentId: episodeContentId,
                      watchContentId: 'episode:${episode.id}',
                    ),
                  ),
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: () => _playContent(
                      episode.url,
                      episode.title,
                      contentId: episodeContentId,
                      watchContentId: 'episode:${episode.id}',
                    ),
                    child: const Icon(
                      Icons.play_circle_outline,
                      color: AppColors.accentPrimary,
                      size: 28,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpgTile(EpgProgramme programme, {required bool isLive}) {
    final startH = programme.start.hour.toString().padLeft(2, '0');
    final startM = programme.start.minute.toString().padLeft(2, '0');
    final stopH = programme.stop.hour.toString().padLeft(2, '0');
    final stopM = programme.stop.minute.toString().padLeft(2, '0');
    final timeRange = '$startH:$startM - $stopH:$stopM';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isLive
            ? AppColors.accentPrimary.withValues(alpha: 0.15)
            : AppColors.bgSurface,
        borderRadius: BorderRadius.circular(8),
        border: isLive
            ? Border.all(
                color: AppColors.accentPrimary.withValues(alpha: 0.4),
                width: 1,
              )
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -- Header row: label + time ------------------------------------
          Row(
            children: [
              if (isLive)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.accentPrimary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'NOW',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.bgElevated,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'NEXT',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Text(
                timeRange,
                style: TextStyle(
                  color: isLive
                      ? AppColors.accentPrimary
                      : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // -- Programme title ---------------------------------------------
          Text(
            programme.title,
            style: TextStyle(
              color: isLive ? AppColors.textPrimary : AppColors.textSecondary,
              fontSize: 16,
              fontWeight: isLive ? FontWeight.w600 : FontWeight.w500,
            ),
          ),

          // -- Description -------------------------------------------------
          if (programme.description != null &&
              programme.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                programme.description!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPosterPlaceholder() {
    return Container(
      color: AppColors.bgSurface,
      child: const Center(
        child: Icon(
          Icons.movie,
          color: AppColors.bgElevated,
          size: 80,
        ),
      ),
    );
  }
}

/// Internal model for episodes.
class _EpisodeItem {
  const _EpisodeItem({
    required this.id,
    required this.season,
    required this.episode,
    required this.title,
    required this.url,
    this.thumbnail,
  });

  final int id;
  final int season;
  final int episode;
  final String title;
  final String url;
  final String? thumbnail;
}

/// Lightweight row model for the additional-info section.
class _InfoRow {
  const _InfoRow(this.icon, this.label, this.value);
  final IconData icon;
  final String label;
  final String value;
}
