import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/data/database.dart';
import '../../core/data/watch_progress_service.dart';
import '../../core/player/player_controller.dart';
import '../../core/theme/app_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/data/offline_download_service.dart';
import '../../core/widgets/favorite_button.dart';
import 'widgets/player_overlay_widgets.dart';

/// Full-screen TV / Fire TV player with D-pad controls and advanced overlays.
///
/// D-pad mapping:
/// - **Left / Right** arrows: seek +/- 10 s
/// - **Select / Enter / Space**: toggle play / pause
/// - **Up**: show controls (if hidden)
/// - **Down**: hide controls
/// - **Back / Escape**: exit player
///
/// Controls are visible by default and auto-hide after 5 seconds.
class TvPlayerScreen extends StatefulWidget {
  const TvPlayerScreen({
    super.key,
    required this.controller,
    this.title = '',
    this.isLive = false,
    this.category,
    this.contentType,
    this.onNextChannel,
    this.onPreviousChannel,
    this.contentId,
    this.startPosition,
    this.poster,
    this.url,
  });

  final PlayerController controller;

  /// Display name shown in the top overlay.
  final String title;

  /// When true the seek bar shows a live indicator instead of a slider.
  final bool isLive;

  /// Channel group / category name (e.g. "Sports", "Movies 4K").
  final String? category;

  /// Content type: "live", "vod", "series", "radio".
  final String? contentType;

  /// Called when the user triggers "next channel" via D-pad or button.
  final VoidCallback? onNextChannel;

  /// Called when the user triggers "previous channel" via D-pad or button.
  final VoidCallback? onPreviousChannel;

  /// Polymorphic watch-progress key (e.g. `"vod:42"`, `"episode:12"`).
  ///
  /// When null (or when [isLive] is true) no watch progress is recorded.
  final String? contentId;

  /// Saved position to resume from, once the media duration is known.
  final Duration? startPosition;

  /// Poster / thumbnail URL for favourites and downloads.
  final String? poster;

  /// Stream URL for downloads.
  final String? url;

  @override
  State<TvPlayerScreen> createState() => _TvPlayerScreenState();
}

class _TvPlayerScreenState extends State<TvPlayerScreen> {
  bool _controlsVisible = true;
  Timer? _hideTimer;
  final FocusNode _focusNode = FocusNode();

  // -- Watch progress ---------------------------------------------------------
  late final WatchProgressService _watchService;
  Timer? _progressTimer;
  bool _wasPlaying = false;

  /// True until the saved [TvPlayerScreen.startPosition] has actually been
  /// applied to the player. While pending, progress is NOT saved — the
  /// position would be ~0 and would clobber the very progress we are
  /// resuming from.
  bool _resumePending = false;
  int _resumeAttempts = 0;
  DateTime? _lastResumeAttempt;
  bool _completed = false;
  EpisodeUpNext? _upNext;
  StreamSubscription<Duration>? _durationSub;

  /// True when watch progress should be recorded for this session.
  bool get _recordsProgress =>
      widget.contentId != null && widget.contentId!.isNotEmpty && !widget.isLive;

  // -- Subtitle preferences --------------------------------------------------
  double _subtitleFontSize = 18.0;
  double _subtitleBgOpacity = 0.6;
  double _subtitleOffset = 0.0;
  bool _subtitleOutline = true;

  @override
  void initState() {
    super.initState();
    _startHideTimer();

    if (_recordsProgress) {
      _watchService = WatchProgressService(database: AppDatabase());
      // Save progress every 10 seconds while the player is open.
      _progressTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _saveWatchProgress(),
      );
      widget.controller.addListener(_onPlayerChanged);
      if (widget.startPosition != null &&
          widget.startPosition! > Duration.zero) {
        _resumePending = true;
        // The duration may already be known (e.g. a fast-loading local
        // file that finished opening before this screen subscribed) —
        // attempt the resume right away instead of waiting for the next
        // player notification.
        _tryResume();

        // Listen for duration becoming available (the player may still be
        // opening/buffering). When duration arrives, seek immediately.
        _durationSub =
            widget.controller.player.stream.duration.listen((d) {
          if (d > Duration.zero && _resumePending && mounted) {
            // ignore: avoid_print
            print('[TvPlayerScreen] Duration available (${d.inSeconds}s) — seeking to ${widget.startPosition!.inSeconds}s');
            widget.controller.seek(widget.startPosition!);
            // Verify seek took effect after a brief delay.
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted && _resumePending) {
                if (widget.controller.position +
                        const Duration(seconds: 5) >=
                    widget.startPosition!) {
                  _resumePending = false;
                  _durationSub?.cancel();
                  _durationSub = null;
                  widget.controller.play();
                }
              }
            });
          }
        });
        // Note: the subscription is NOT cancelled on a fixed timer — slow
        // streams can take longer than 10 s to report a duration, and
        // cancelling early would strand the pending resume. It is cancelled
        // once the resume succeeds (or is abandoned) in [_tryResume], and
        // always in dispose().
      }
      // Preload the next episode (for series episodes) for the Up Next overlay.
      final id = widget.contentId;
      if (id != null && id.startsWith('episode:')) {
        _watchService.getUpNext(id).then((upNext) {
          if (mounted) setState(() => _upNext = upNext);
        });
      }
    }

    // Load subtitle preferences.
    _loadSubtitlePrefs().then((_) {
      _applySubtitleStyle();
      _applySubtitlePosition(_subtitleOffset);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _durationSub?.cancel();
    if (_recordsProgress) {
      _progressTimer?.cancel();
      widget.controller.removeListener(_onPlayerChanged);
      // Save final position when the user leaves the player.
      _saveWatchProgress();
    }
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Watch progress
  // ---------------------------------------------------------------------------

  /// Persists the current playback position for Continue Watching.
  void _saveWatchProgress() {
    // Never persist while the resume seek is still pending — the position
    // is still ~0 and saving would destroy the saved progress we are
    // trying to resume from (making the next launch restart from the
    // beginning).
    if (_resumePending) return;
    final id = widget.contentId;
    if (id == null || id.isEmpty) return;
    final ctrl = widget.controller;
    final durationMs = ctrl.duration.inMilliseconds;
    if (durationMs <= 0) return;
    _watchService.saveProgress(
      id,
      ctrl.position.inMilliseconds,
      durationMs,
    );
  }

  /// Attempts to seek to [TvPlayerScreen.startPosition] once the media
  /// duration is known.
  ///
  /// Seeks issued while the stream is still opening/buffering can be
  /// silently dropped by the playback engine, so the seek is retried
  /// (rate-limited) until playback actually reaches the target position.
  /// Only then is `_resumePending` cleared and progress saving re-enabled.
  void _tryResume() {
    if (!_resumePending) return;
    final target = widget.startPosition;
    if (target == null || target <= Duration.zero) {
      _resumePending = false;
      return;
    }
    final ctrl = widget.controller;

    // Wait until the duration is known before seeking.
    if (ctrl.duration <= Duration.zero) return;

    // The seek took effect once playback reaches (near) the target.
    if (ctrl.position + const Duration(seconds: 5) >= target) {
      _resumePending = false;
      // Resume verified — the duration listener is no longer needed.
      _durationSub?.cancel();
      _durationSub = null;
      return;
    }

    // Give up after too many attempts (e.g. an unseekable stream) and
    // simply play from the start.
    if (_resumeAttempts >= 30) {
      _resumePending = false;
      // Resume abandoned — the duration listener is no longer needed.
      _durationSub?.cancel();
      _durationSub = null;
      return;
    }

    // Rate-limit retries so we don't hammer the player on every position
    // tick while the stream is still buffering.
    final now = DateTime.now();
    if (_lastResumeAttempt != null &&
        now.difference(_lastResumeAttempt!) <
            const Duration(milliseconds: 500)) {
      return;
    }
    _resumeAttempts++;
    _lastResumeAttempt = now;

    // ignore: avoid_print
    print('[TvPlayerScreen] _tryResume attempt $_resumeAttempts → seeking to ${target.inSeconds}s (current: ${ctrl.position.inSeconds}s, duration: ${ctrl.duration.inSeconds}s)');
    ctrl.seek(target);
    // Resume playback after seeking (the player was paused during resume).
    if (!ctrl.isPlaying) {
      ctrl.play();
    }
  }

  /// Reacts to player state changes: resume seek, pause save, completion.
  void _onPlayerChanged() {
    final ctrl = widget.controller;

    // Retry / verify the resume seek on every player notification.
    _tryResume();

    // Treat >= 95% watched as completed: drop from Continue Watching.
    if (!_completed &&
        ctrl.duration > Duration.zero &&
        ctrl.position.inMilliseconds >=
            ctrl.duration.inMilliseconds * 0.95) {
      _completed = true;
      _progressTimer?.cancel();
      _watchService.clearProgress(widget.contentId!);
    }

    // Save an immediate snapshot when playback pauses.
    if (_wasPlaying && !ctrl.isPlaying) {
      _saveWatchProgress();
    }
    _wasPlaying = ctrl.isPlaying;
  }

  // ---------------------------------------------------------------------------
  // Controls visibility
  // ---------------------------------------------------------------------------

  void _showControls() {
    setState(() => _controlsVisible = true);
    _startHideTimer();
  }

  void _hideControls() {
    if (mounted) setState(() => _controlsVisible = false);
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), _hideControls);
  }

  // ---------------------------------------------------------------------------
  // D-pad key handling
  // ---------------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final ctrl = widget.controller;

    switch (event.logicalKey) {
      // Center / Select / Enter / Space => toggle play/pause
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        ctrl.togglePlay();
        _showControls();
        return KeyEventResult.handled;

      // Left arrow => seek backward 10 s
      case LogicalKeyboardKey.arrowLeft:
        ctrl.seekBy(const Duration(seconds: -10));
        _showControls();
        return KeyEventResult.handled;

      // Right arrow => seek forward 10 s
      case LogicalKeyboardKey.arrowRight:
        ctrl.seekBy(const Duration(seconds: 10));
        _showControls();
        return KeyEventResult.handled;

      // Up arrow => show controls (if hidden)
      case LogicalKeyboardKey.arrowUp:
        _showControls();
        return KeyEventResult.handled;

      // Down arrow => hide controls
      case LogicalKeyboardKey.arrowDown:
        _hideControls();
        return KeyEventResult.handled;

      // Back / Escape => exit player
      case LogicalKeyboardKey.goBack:
      case LogicalKeyboardKey.escape:
        if (mounted) Navigator.of(context).pop();
        return KeyEventResult.handled;

      default:
        return KeyEventResult.ignored;
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          autofocus: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // -- Video surface ---------------------------------------------
              Center(
                child: Video(
                  key: ValueKey('$_subtitleOffset-$_subtitleOutline-$_subtitleFontSize-$_subtitleBgOpacity'),
                  controller: ctrl.videoController,
                  controls: (state) => const SizedBox.shrink(),
                  subtitleViewConfiguration: _buildSubtitleConfig(),
                ),
              ),

              // -- Buffering indicator ---------------------------------------
              _buildBufferingOverlay(ctrl),

              // -- Up Next overlay (series episodes) --------------------------
              _buildUpNextOverlay(ctrl),

              // -- Overlay controls ------------------------------------------
              IgnorePointer(
                ignoring: !_controlsVisible,
                child: _buildControls(ctrl),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Up Next overlay
  // ---------------------------------------------------------------------------

  /// Shows a brief "Up Next: <title>" card during the last 20 seconds of a
  /// series episode. Hidden when no next episode is known.
  Widget _buildUpNextOverlay(PlayerController ctrl) {
    return Positioned(
      left: 48,
      right: 48,
      bottom: 140,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: ctrl,
          builder: (context, _) {
            final upNext = _upNext;
            if (upNext == null || ctrl.duration <= Duration.zero) {
              return const SizedBox.shrink();
            }
            final fraction = ctrl.seekFraction;
            final remaining = ctrl.duration - ctrl.position;
            final visible = remaining <= const Duration(seconds: 20) &&
                fraction >= 0.9 &&
                fraction < 0.99;
            if (!visible) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.accentPrimary, width: 2),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Up Next',
                      style: TextStyle(
                        color: AppColors.accentPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      upNext.label,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Buffering overlay
  // ---------------------------------------------------------------------------

  Widget _buildBufferingOverlay(PlayerController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        // -- Error state -------------------------------------------------
        if (ctrl.hasError) {
          return Container(
            color: Colors.black87,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 56,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      ctrl.error ?? 'Playback error',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      autofocus: true,
                      onPressed: () => ctrl.retry(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accentPrimary,
                        foregroundColor: AppColors.textPrimary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // -- Buffering state ---------------------------------------------
        if (!ctrl.isBuffering) return const SizedBox.shrink();
        return Container(
          color: Colors.black45,
          child: const Center(
            child: CircularProgressIndicator(color: AppColors.accentPrimary),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Controls overlay
  // ---------------------------------------------------------------------------

  Widget _buildControls(PlayerController ctrl) {
    return AnimatedOpacity(
      opacity: _controlsVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black87,
              Colors.transparent,
              Colors.transparent,
              Colors.black87,
            ],
            stops: [0.0, 0.25, 0.65, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // -- Top: title + track buttons --------------------------------
              _buildTopBar(ctrl),

              const Spacer(),

              // -- Center: play/pause + next/prev ----------------------------
              _buildCenterArea(ctrl),

              // -- Bottom: progress bar + timestamps + D-pad hints -----------
              _buildProgressBarArea(ctrl),
              const SizedBox(height: 8),
              if (!widget.isLive) _buildDpadHints(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(PlayerController ctrl) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          const Icon(Icons.arrow_back,
              color: AppColors.textSecondary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: StreamInfoOverlay(
              title: widget.title,
              category: widget.category,
              resolution: ctrl.videoResolution,
              contentType: widget.contentType,
            ),
          ),
          // Audio track button (only if multiple tracks)
          AnimatedBuilder(
            animation: ctrl,
            builder: (context, _) {
              if (ctrl.hasMultipleAudioTracks) {
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _TvIconButton(
                    icon: Icons.audiotrack,
                    tooltip: 'Audio tracks',
                    onPressed: () async {
                      final track = await showAudioTrackSelector(
                        context,
                        tracks: ctrl.audioTracks,
                        current: ctrl.currentAudioTrack,
                      );
                      if (track != null) ctrl.setAudioTrack(track);
                    },
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          // Subtitle track button (only if subtitles available)
          AnimatedBuilder(
            animation: ctrl,
            builder: (context, _) {
              if (ctrl.hasSubtitleTracks) {
                final hasActive =
                    ctrl.currentSubtitleTrack != SubtitleTrack.no();
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _TvIconButton(
                    icon: Icons.subtitles,
                    tooltip: 'Subtitles',
                    color: hasActive ? AppColors.accentPrimary : null,
                    onPressed: () async {
                      final track = await showSubtitleTrackSelector(
                        context,
                        tracks: ctrl.subtitleTracks,
                        current: ctrl.currentSubtitleTrack,
                      );
                      if (track != null) ctrl.setSubtitleTrack(track);
                    },
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          // Subtitle settings button
          if (widget.contentId != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _TvIconButton(
                icon: Icons.closed_caption,
                tooltip: 'Subtitle settings',
                onPressed: _showSubtitleSettings,
              ),
            ),
          // Favorite button
          if (widget.contentId != null && widget.contentType != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FavoriteButton(
                contentId: widget.contentId!,
                contentType: widget.contentType!,
                title: widget.title,
                poster: widget.poster,
                url: widget.url,
                size: 22,
              ),
            ),
          // Download button
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _TvDownloadOverlayButton(
              contentId: widget.contentId ?? '',
              url: widget.url ?? '',
              title: widget.title,
              contentType: widget.contentType ?? '',
              thumbnailUrl: widget.poster,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterArea(PlayerController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Next/Prev buttons for live TV
            if (widget.isLive &&
                (widget.onNextChannel != null ||
                    widget.onPreviousChannel != null))
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: NextPrevChannelButtons(
                  onPrevious: widget.onPreviousChannel,
                  onNext: widget.onNextChannel,
                ),
              ),

            // Play/Pause indicator
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.accentPrimary.withValues(alpha: 0.8),
                shape: BoxShape.circle,
              ),
              child: Icon(
                ctrl.isPlaying ? Icons.pause : Icons.play_arrow,
                color: AppColors.textPrimary,
                size: 40,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProgressBarArea(PlayerController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        return PlayerProgressBar(
          positionText: ctrl.positionText,
          durationText: ctrl.durationText,
          seekFraction: ctrl.seekFraction,
          isLive: widget.isLive,
          onSeek: widget.isLive ? null : ctrl.seekFractionally,
        );
      },
    );
  }

  Widget _buildDpadHints() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _hintChip(Icons.fast_rewind, '10s'),
        const SizedBox(width: 24),
        _hintChip(Icons.play_arrow, 'Play'),
        const SizedBox(width: 24),
        _hintChip(Icons.fast_forward, '10s'),
      ],
    );
  }

  Widget _hintChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.bgSurface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 16),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Subtitle configuration
  // ---------------------------------------------------------------------------

  /// Builds a [SubtitleViewConfiguration] from the current subtitle prefs.
  SubtitleViewConfiguration _buildSubtitleConfig() {
    return SubtitleViewConfiguration(
      style: TextStyle(
        fontSize: _subtitleFontSize,
        color: Colors.white,
        backgroundColor: Colors.black.withValues(alpha: _subtitleBgOpacity),
        shadows: _subtitleOutline
            ? [
                const Shadow(offset: Offset(-1, -1), color: Colors.black, blurRadius: 0),
                const Shadow(offset: Offset(1, -1), color: Colors.black, blurRadius: 0),
                const Shadow(offset: Offset(-1, 1), color: Colors.black, blurRadius: 0),
                const Shadow(offset: Offset(1, 1), color: Colors.black, blurRadius: 0),
              ]
            : null,
      ),
      textScaler: const TextScaler.linear(1.0),
      padding: EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 24.0 + (_subtitleOffset * 100)),
    );
  }

  // ---------------------------------------------------------------------------
  // Subtitle settings
  // ---------------------------------------------------------------------------

  Future<void> _loadSubtitlePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _subtitleFontSize = prefs.getDouble('subtitle_font_size') ?? 18.0;
        _subtitleBgOpacity = prefs.getDouble('subtitle_bg_opacity') ?? 0.6;
        _subtitleOffset = prefs.getDouble('subtitle_offset') ?? 0.0;
        _subtitleOutline = prefs.getBool('subtitle_outline') ?? true;
      });
    }
  }

  void _applySubtitlePosition(double offset) {
    // Subtitle position is applied via SubtitleViewConfiguration padding.
    setState(() {});
  }

  void _applySubtitleStyle() {
    // Subtitle style is applied via SubtitleViewConfiguration.
    setState(() {});
  }

  void _showSubtitleSettings() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.bgSurface,
              title: const Text(
                'Subtitle Settings',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Font Size: ${_subtitleFontSize.round()}px',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _tvFontSizeButton(14, setDialogState),
                      const SizedBox(width: 8),
                      _tvFontSizeButton(18, setDialogState),
                      const SizedBox(width: 8),
                      _tvFontSizeButton(24, setDialogState),
                      const SizedBox(width: 8),
                      _tvFontSizeButton(32, setDialogState),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Background Opacity: ${(_subtitleBgOpacity * 100).round()}%',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: AppColors.accentPrimary,
                      inactiveTrackColor: AppColors.bgSurface,
                      thumbColor: AppColors.accentPrimary,
                      overlayColor: AppColors.accentPrimary.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      value: _subtitleBgOpacity,
                      min: 0.0,
                      max: 1.0,
                      divisions: 10,
                      onChanged: (val) async {
                        setDialogState(() => _subtitleBgOpacity = val);
                        setState(() => _subtitleBgOpacity = val);
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setDouble('subtitle_bg_opacity', val);
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Subtitle vertical position
                  const Text(
                    'Vertical Position',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            activeTrackColor: AppColors.accentPrimary,
                            inactiveTrackColor: AppColors.bgSurface,
                            thumbColor: AppColors.accentPrimary,
                            overlayColor: AppColors.accentPrimary.withValues(alpha: 0.2),
                          ),
                          child: Slider(
                            value: _subtitleOffset,
                            min: -1.0,
                            max: 1.0,
                            divisions: 20,
                            onChanged: (v) async {
                              setDialogState(() => _subtitleOffset = v);
                              setState(() => _subtitleOffset = v);
                              _applySubtitlePosition(v);
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.setDouble('subtitle_offset', v);
                            },
                          ),
                        ),
                      ),
                      const Icon(Icons.arrow_drop_up, color: AppColors.textSecondary),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Subtitle outline toggle
                  SwitchListTile(
                    title: const Text('Text Outline', style: TextStyle(color: AppColors.textPrimary)),
                    subtitle: const Text('Black outline around subtitle text', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    value: _subtitleOutline,
                    onChanged: (v) async {
                      setDialogState(() => _subtitleOutline = v);
                      setState(() => _subtitleOutline = v);
                      _applySubtitleStyle();
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('subtitle_outline', v);
                    },
                    activeThumbColor: AppColors.accentPrimary,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Styling will be applied when subtitle rendering is enabled.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Done',
                    style: TextStyle(color: AppColors.accentPrimary),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _tvFontSizeButton(double size, StateSetter setDialogState) {
    final isSelected = (_subtitleFontSize - size).abs() < 0.01;
    return Expanded(
      child: GestureDetector(
        onTap: () async {
          setDialogState(() => _subtitleFontSize = size);
          setState(() => _subtitleFontSize = size);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setDouble('subtitle_font_size', size);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.accentPrimary
                : AppColors.bgSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? AppColors.accentPrimary
                  : AppColors.textSecondary,
            ),
          ),
          child: Text(
            '${size.round()}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color:
                  isSelected ? AppColors.textPrimary : AppColors.textSecondary,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

/// Focusable icon button for TV/D-pad navigation.
class _TvIconButton extends StatelessWidget {
  const _TvIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter)) {
          onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final focused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: onPressed,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: focused
                    ? AppColors.accentPrimary.withValues(alpha: 0.3)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: focused
                    ? Border.all(color: AppColors.accentPrimary, width: 2)
                    : null,
              ),
              child: Tooltip(
                message: tooltip ?? '',
                child: Icon(
                  icon,
                  color: color ?? AppColors.textPrimary,
                  size: 24,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Download button for the TV player overlay.
///
/// Uses [_TvIconButton] for D-pad focusability and triggers
/// [OfflineDownloadService.enqueueDownload] on activation.
class _TvDownloadOverlayButton extends StatefulWidget {
  const _TvDownloadOverlayButton({
    required this.contentId,
    required this.url,
    required this.title,
    required this.contentType,
    this.thumbnailUrl,
  });

  final String contentId;
  final String url;
  final String title;
  final String contentType;
  final String? thumbnailUrl;

  @override
  State<_TvDownloadOverlayButton> createState() =>
      _TvDownloadOverlayButtonState();
}

class _TvDownloadOverlayButtonState extends State<_TvDownloadOverlayButton> {
  final _service = OfflineDownloadService.instance;
  bool _isDownloaded = false;

  @override
  void initState() {
    super.initState();
    _checkDownloaded();
  }

  bool get _canDownload =>
      widget.contentId.isNotEmpty && widget.url.isNotEmpty;

  Future<void> _checkDownloaded() async {
    if (!_canDownload) return;
    final result = await _service.isDownloaded(widget.contentId);
    if (mounted) setState(() => _isDownloaded = result);
  }

  Future<void> _onTap() async {
    if (!_canDownload) return;
    if (_isDownloaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Already downloaded'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await _service.enqueueDownload(
      contentId: widget.contentId,
      url: widget.url,
      title: widget.title,
      contentType: widget.contentType,
      thumbnailUrl: widget.thumbnailUrl,
    );
    if (!mounted) return;
    // Re-check in case the item was hydrated as already downloaded.
    if (_isDownloaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Already downloaded'),
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Download started'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return _TvIconButton(
      icon: _isDownloaded ? Icons.download_done : Icons.download,
      tooltip: _isDownloaded ? 'Downloaded' : 'Download',
      color: _isDownloaded ? AppColors.accentPrimary : null,
      onPressed: _onTap,
    );
  }
}
