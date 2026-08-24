import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/data/database.dart';
import '../../core/data/watch_progress_service.dart';
import '../../core/player/brightness_service.dart';
import '../../core/player/player_controller.dart';
import '../../core/theme/app_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/data/offline_download_service.dart';
import '../../core/widgets/favorite_button.dart';
import 'widgets/player_overlay_widgets.dart';

/// Full-screen mobile video player with advanced overlay controls.
///
/// Features:
/// - Tap to show/hide controls (auto-hide after 5 s)
/// - Swipe left side up/down to adjust brightness
/// - Swipe right side up/down to adjust volume
/// - Next / previous channel buttons (live TV)
/// - Audio track selector
/// - Subtitle track selector
/// - Stream info overlay (title, category, resolution)
/// - Seek bar (VOD/series) or live indicator
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
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

  /// Called when the user taps the "next channel" button.
  final VoidCallback? onNextChannel;

  /// Called when the user taps the "previous channel" button.
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
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _controlsVisible = true;
  Timer? _hideTimer;

  // Keyboard shortcut focus node (for external keyboards / BT remotes).
  final FocusNode _focusNode = FocusNode();

  // -- Brightness / volume swipe state --------------------------------------
  double _brightness = 0.5;
  double _volumeFraction = 1.0;
  bool _showBrightnessIndicator = false;
  bool _showVolumeIndicator = false;
  Timer? _indicatorHideTimer;

  // Track whether the user is currently swiping (to suppress tap).
  bool _isSwiping = false;
  double _swipeStartY = 0;

  // -- Double-tap seek -------------------------------------------------------
  Timer? _singleTapTimer;
  bool _showLeftSeekIcon = false;
  bool _showRightSeekIcon = false;
  Timer? _seekIconTimer;

  // -- Subtitle preferences --------------------------------------------------
  double _subtitleFontSize = 18.0;
  double _subtitleBgOpacity = 0.6;
  double _subtitleOffset = 0.0;
  bool _subtitleOutline = true;

  // -- Watch progress ---------------------------------------------------------
  late final WatchProgressService _watchService;
  Timer? _progressTimer;
  bool _wasPlaying = false;

  /// True until the saved [PlayerScreen.startPosition] has actually been
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
            print('[PlayerScreen] Duration available (${d.inSeconds}s) — seeking to ${widget.startPosition!.inSeconds}s');
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
        // Cancel after 10 seconds to avoid leaks.
        Future.delayed(const Duration(seconds: 10), () {
          _durationSub?.cancel();
          _durationSub = null;
        });
      }
      // Preload the next episode (for series episodes) for the Up Next overlay.
      final id = widget.contentId;
      if (id != null && id.startsWith('episode:')) {
        _watchService.getUpNext(id).then((upNext) {
          if (mounted) setState(() => _upNext = upNext);
        });
      }
    }

    // Initialize brightness from service.
    BrightnessService.initialize().then((b) {
      if (mounted) setState(() => _brightness = b);
    });

    // Load subtitle preferences.
    _loadSubtitlePrefs().then((_) {
      _applySubtitleStyle();
      _applySubtitlePosition(_subtitleOffset);
    });

    // Sync volume fraction from controller.
    _volumeFraction = widget.controller.volumeFraction;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _indicatorHideTimer?.cancel();
    _singleTapTimer?.cancel();
    _seekIconTimer?.cancel();
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

  /// Attempts to seek to [PlayerScreen.startPosition] once the media
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
      return;
    }

    // Give up after too many attempts (e.g. an unseekable stream) and
    // simply play from the start.
    if (_resumeAttempts >= 30) {
      _resumePending = false;
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
    print('[PlayerScreen] _tryResume attempt $_resumeAttempts → seeking to ${target.inSeconds}s (current: ${ctrl.position.inSeconds}s, duration: ${ctrl.duration.inSeconds}s)');
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

  void _onScreenTap() {
    if (_isSwiping) return; // Ignore taps that are actually swipes.
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  /// Back-button logic: hide controls first, exit only when already hidden.
  Future<bool> _onWillPop() async {
    if (_controlsVisible) {
      _hideControls();
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Brightness / Volume swipe gestures
  // ---------------------------------------------------------------------------

  void _onVerticalDragStart(DragStartDetails details) {
    _isSwiping = false;
    _swipeStartY = details.globalPosition.dy;
    _startHideTimer(); // Keep controls visible during swipe.
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isLeftSide = details.globalPosition.dx < screenWidth / 2;

    // Calculate delta: swipe up = positive, swipe down = negative.
    final delta = (_swipeStartY - details.globalPosition.dy) / 200;
    _swipeStartY = details.globalPosition.dy;

    if (delta.abs() > 0.005) {
      _isSwiping = true;
    }

    if (isLeftSide) {
      // Brightness
      _brightness = (_brightness + delta).clamp(0.0, 1.0);
      BrightnessService.setBrightness(_brightness);
      setState(() {
        _showBrightnessIndicator = true;
        _showVolumeIndicator = false;
      });
    } else {
      // Volume
      _volumeFraction = (_volumeFraction + delta).clamp(0.0, 1.0);
      widget.controller.setVolumeFraction(_volumeFraction);
      setState(() {
        _showVolumeIndicator = true;
        _showBrightnessIndicator = false;
      });
    }

    _resetIndicatorTimer();
    _startHideTimer(); // Reset auto-hide while user is swiping.
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    // Start fading the indicator after a short delay.
    _resetIndicatorTimer();
    _startHideTimer(); // Reset auto-hide after swipe ends.
  }

  void _resetIndicatorTimer() {
    _indicatorHideTimer?.cancel();
    _indicatorHideTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _showBrightnessIndicator = false;
          _showVolumeIndicator = false;
        });
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Keyboard shortcuts (for external keyboards / BT remotes on phones)
  // ---------------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final ctrl = widget.controller;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.select:
        ctrl.togglePlay();
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        ctrl.seekBy(const Duration(seconds: -10));
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        ctrl.seekBy(const Duration(seconds: 10));
        _showControls();
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
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              _singleTapTimer?.cancel();
              _singleTapTimer = Timer(const Duration(milliseconds: 250), () {
                _onScreenTap();
              });
            },
            onDoubleTapDown: (details) {
              _singleTapTimer?.cancel();
              _onDoubleTap(details);
            },
            onVerticalDragStart: _onVerticalDragStart,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // -- Video surface -------------------------------------------
                Center(
                  child: Video(
                    controller: ctrl.videoController,
                    controls: (state) => const SizedBox.shrink(),
                    subtitleViewConfiguration: _buildSubtitleConfig(),
                  ),
                ),

                // -- Loading spinner -----------------------------------------
                _buildBufferingOverlay(ctrl),

                // -- Brightness indicator (left side) ------------------------
                Positioned(
                  left: 40,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AdjustIndicator(
                      icon: _brightness > 0.5
                          ? Icons.brightness_high
                          : _brightness > 0
                              ? Icons.brightness_low
                              : Icons.brightness_1,
                      value: _brightness,
                      visible: _showBrightnessIndicator,
                    ),
                  ),
                ),

                // -- Volume indicator (right side) ---------------------------
                Positioned(
                  right: 40,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AdjustIndicator(
                      icon: _volumeFraction > 0.5
                          ? Icons.volume_up
                          : _volumeFraction > 0
                              ? Icons.volume_down
                              : Icons.volume_off,
                      value: _volumeFraction,
                      visible: _showVolumeIndicator,
                    ),
                  ),
                ),

                // -- Up Next overlay (series episodes) ------------------------
                _buildUpNextOverlay(ctrl),

                // -- Double-tap seek icons ------------------------------------
                _buildSeekIconOverlay(),

                // -- Overlay controls ----------------------------------------
                IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: _buildControls(ctrl),
                ),
              ],
            ),
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
      left: 16,
      right: 16,
      bottom: 110,
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
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.accentPrimary),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Up Next',
                      style: TextStyle(
                        color: AppColors.accentPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      upNext.label,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
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
        // Suppress error overlay if the video is actually playing
        // (codec warnings can fire while playback continues fine).
        if (ctrl.hasError && !ctrl.isPlaying) {
          return Container(
            color: Colors.black87,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      ctrl.error ?? 'Playback error',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      onPressed: () => ctrl.retry(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accentPrimary,
                        foregroundColor: AppColors.textPrimary,
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
      duration: const Duration(milliseconds: 250),
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
            stops: [0.0, 0.2, 0.7, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // -- Top bar: back + title + track buttons ---------------------
              _buildTopBar(ctrl),

              // -- Spacer ---------------------------------------------------
              const Spacer(),

              // -- Center: play/pause + next/prev ----------------------------
              _buildCenterArea(ctrl),

              // -- Bottom: progress bar + timestamps -------------------------
              _buildProgressBarArea(ctrl),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(PlayerController ctrl) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            onPressed: () {
              if (mounted) Navigator.of(context).pop();
            },
          ),
          const SizedBox(width: 4),
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
                return IconButton(
                  icon: const Icon(Icons.audiotrack,
                      color: AppColors.textPrimary),
                  tooltip: 'Audio tracks',
                  onPressed: () async {
                    final track = await showAudioTrackSelector(
                      context,
                      tracks: ctrl.audioTracks,
                      current: ctrl.currentAudioTrack,
                    );
                    if (track != null) ctrl.setAudioTrack(track);
                  },
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
                return IconButton(
                  icon: Icon(
                    Icons.subtitles,
                    color: hasActive
                        ? AppColors.accentPrimary
                        : AppColors.textPrimary,
                  ),
                  tooltip: 'Subtitles',
                  onPressed: () async {
                    final track = await showSubtitleTrackSelector(
                      context,
                      tracks: ctrl.subtitleTracks,
                      current: ctrl.currentSubtitleTrack,
                    );
                    if (track != null) ctrl.setSubtitleTrack(track);
                  },
                );
              }
              return const SizedBox.shrink();
            },
          ),
          // Subtitle settings button
          if (widget.contentId != null)
            IconButton(
              icon: const Icon(Icons.closed_caption,
                  color: AppColors.textPrimary),
              tooltip: 'Subtitle settings',
              onPressed: _showSubtitleSettings,
            ),
          // Favorite button
          if (widget.contentId != null && widget.contentType != null)
            FavoriteButton(
              contentId: widget.contentId!,
              contentType: widget.contentType!,
              title: widget.title,
              poster: widget.poster,
              url: widget.url,
              size: 22,
            ),
          // Download button
          _DownloadOverlayButton(
            contentId: widget.contentId ?? '',
            url: widget.url ?? '',
            title: widget.title,
            contentType: widget.contentType ?? '',
            thumbnailUrl: widget.poster,
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
                padding: const EdgeInsets.only(bottom: 16),
                child: NextPrevChannelButtons(
                  onPrevious: widget.onPreviousChannel,
                  onNext: widget.onNextChannel,
                ),
              ),

            // Play/Pause button
            GestureDetector(
              onTap: () {
                ctrl.togglePlay();
                _startHideTimer(); // Reset auto-hide on interaction.
              },
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.accentPrimary.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  ctrl.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: AppColors.textPrimary,
                  size: 36,
                ),
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
          onSeek: widget.isLive
              ? null
              : (fraction) {
                  ctrl.seekFractionally(fraction);
                  _startHideTimer(); // Reset auto-hide on seek.
                },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Double-tap seek
  // ---------------------------------------------------------------------------

  void _onDoubleTap(TapDownDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isLeft = details.localPosition.dx < screenWidth / 2;

    if (isLeft) {
      widget.controller.seekBy(const Duration(seconds: -15));
      setState(() => _showLeftSeekIcon = true);
    } else {
      widget.controller.seekBy(const Duration(seconds: 15));
      setState(() => _showRightSeekIcon = true);
    }

    _seekIconTimer?.cancel();
    _seekIconTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _showLeftSeekIcon = false;
          _showRightSeekIcon = false;
        });
      }
    });
    _startHideTimer();
  }

  Widget _buildSeekIconOverlay() {
    return IgnorePointer(
      child: Stack(
        children: [
          // Left seek icon
          Positioned(
            left: 40,
            top: 0,
            bottom: 0,
            child: Center(
              child: AnimatedOpacity(
                opacity: _showLeftSeekIcon ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.fast_rewind, color: Colors.white, size: 28),
                      SizedBox(width: 4),
                      Text(
                        '15',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Right seek icon
          Positioned(
            right: 40,
            top: 0,
            bottom: 0,
            child: Center(
              child: AnimatedOpacity(
                opacity: _showRightSeekIcon ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '15',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(Icons.fast_forward, color: Colors.white, size: 28),
                    ],
                  ),
                ),
              ),
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
    // The Video widget rebuilds when setState is called.
    setState(() {});
  }

  void _applySubtitleStyle() {
    // Subtitle style is applied via SubtitleViewConfiguration.
    // The Video widget rebuilds when setState is called.
    setState(() {});
  }

  void _showSubtitleSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: AppColors.textSecondary.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const Text(
                      'Subtitle Settings',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Font size
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
                        _fontSizeButton(14, setModalState),
                        const SizedBox(width: 8),
                        _fontSizeButton(18, setModalState),
                        const SizedBox(width: 8),
                        _fontSizeButton(24, setModalState),
                        const SizedBox(width: 8),
                        _fontSizeButton(32, setModalState),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Background opacity
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
                          setModalState(() => _subtitleBgOpacity = val);
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
                                setModalState(() => _subtitleOffset = v);
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
                        setModalState(() => _subtitleOutline = v);
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
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _fontSizeButton(double size, StateSetter setModalState) {
    final isSelected = (_subtitleFontSize - size).abs() < 0.01;
    return Expanded(
      child: GestureDetector(
        onTap: () async {
          setModalState(() => _subtitleFontSize = size);
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

/// Download button for the player overlay.
///
/// Shows a download icon that triggers [OfflineDownloadService.enqueueDownload]
/// and displays a SnackBar with the result.
class _DownloadOverlayButton extends StatefulWidget {
  const _DownloadOverlayButton({
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
  State<_DownloadOverlayButton> createState() => _DownloadOverlayButtonState();
}

class _DownloadOverlayButtonState extends State<_DownloadOverlayButton> {
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
    return IconButton(
      icon: Icon(
        _isDownloaded ? Icons.download_done : Icons.download,
        color: _isDownloaded ? AppColors.accentPrimary : AppColors.textPrimary,
      ),
      tooltip: _isDownloaded ? 'Downloaded' : 'Download',
      onPressed: _onTap,
    );
  }
}
