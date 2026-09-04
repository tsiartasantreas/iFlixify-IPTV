import 'dart:async';
import 'dart:io';

import 'package:floating/floating.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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

  // -- Long-press 2x speed (YouTube-style) ------------------------------------
  double _rateBeforeBoost = 1.0;
  bool _longPressActive = false;
  bool _showSpeedPill = false;

  // -- Playback settings -------------------------------------------------------
  BoxFit _videoFit = BoxFit.contain;
  Timer? _sleepTimer;
  Timer? _sleepCountdown;
  DateTime? _sleepEndsAt;

  // -- Picture-in-Picture (Android, guarded) -----------------------------------
  bool _pipAvailable = false;
  bool _isInPip = false;
  StreamSubscription<PiPStatus>? _pipStatusSub;

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

    // Keep the screen on and lock to landscape while the player is open.
    WakelockPlus.enable();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _probePipSupport();

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
    _sleepTimer?.cancel();
    _sleepCountdown?.cancel();
    _pipStatusSub?.cancel();
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
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
  Future<void> _saveWatchProgress() async {
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
    await _watchService.saveProgress(
      id,
      ctrl.position.inMilliseconds,
      durationMs,
    );
  }

  /// Cancels the periodic timer and persists the final playback position,
  /// awaiting completion. Pop handlers call this BEFORE removing the route so
  /// the Continue Watching row is guaranteed to be committed before any
  /// parent screen reloads its data (the old fire-and-forget dispose save
  /// raced the parent's reload and the row could appear only on the next
  /// reload).
  Future<void> _flushFinalProgress() async {
    if (!_recordsProgress) return;
    _progressTimer?.cancel();
    _progressTimer = null;
    try {
      await _saveWatchProgress();
    } catch (_) {
      // A failed save must never block navigation.
    }
  }

  /// Exits the player: flushes the final watch-progress save first, then pops.
  Future<void> _exitPlayer() async {
    await _flushFinalProgress();
    if (mounted) Navigator.of(context).pop();
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
  // Picture-in-Picture (Android only, guarded)
  // ---------------------------------------------------------------------------

  /// One-time PiP capability probe. On any failure the PiP button stays
  /// hidden and the feature is entirely inert.
  Future<void> _probePipSupport() async {
    // The floating package only implements PiP on Android; probing elsewhere
    // would just throw, so hide the button entirely on other platforms.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final available = await Floating().isPipAvailable;
      if (!mounted) return;
      setState(() => _pipAvailable = available);
      if (!available) return;
      // Track PiP mode so all overlays can be hidden while active. The video
      // widget (and its controller) stays fully mounted during PiP.
      _pipStatusSub = Floating().pipStatusStream.listen((status) {
        if (!mounted) return;
        setState(() => _isInPip = status == PiPStatus.enabled);
      });
    } catch (_) {
      // PiP unavailable on this device — the button stays hidden.
      if (mounted) setState(() => _pipAvailable = false);
    }
  }

  Future<void> _enterPip() async {
    try {
      await Floating().enable(const ImmediatePiP());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Picture-in-Picture unavailable'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Screenshot
  // ---------------------------------------------------------------------------

  /// Captures the current frame and opens the system share sheet with the
  /// PNG. Never throws — falls back to a toast on failure.
  Future<void> _takeScreenshot() async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await widget.controller.takeScreenshot();
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Screenshot failed'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(file.path)],
        text: widget.title.isEmpty ? null : widget.title,
      );
    } catch (_) {
      // Sharing failed but the capture succeeded — the frame was written to
      // the temporary directory. Never crash the player over sharing.
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Screenshot saved'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Sleep timer
  // ---------------------------------------------------------------------------

  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _sleepCountdown?.cancel();
    setState(() => _sleepEndsAt = null);
    if (minutes <= 0) return;
    _sleepEndsAt = DateTime.now().add(Duration(minutes: minutes));
    _sleepTimer = Timer(Duration(minutes: minutes), _onSleepTimerEnd);
    _sleepCountdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {}); // Refresh the remaining-time display.
    });
  }

  void _onSleepTimerEnd() {
    _sleepCountdown?.cancel();
    _sleepCountdown = null;
    if (!mounted) return;
    setState(() => _sleepEndsAt = null);
    widget.controller.pause();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sleep timer ended'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Formatted remaining sleep-timer time, or null when no timer is active.
  String? get _sleepRemainingText {
    final endsAt = _sleepEndsAt;
    if (endsAt == null) return null;
    final remaining = endsAt.difference(DateTime.now());
    if (remaining <= Duration.zero) return null;
    return '${remaining.inMinutes}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------------------
  // Long-press 2x speed
  // ---------------------------------------------------------------------------

  void _onLongPressStart(LongPressStartDetails details) {
    _singleTapTimer?.cancel();
    _rateBeforeBoost = widget.controller.rate;
    widget.controller.setRate(2.0);
    _startHideTimer();
    setState(() {
      _longPressActive = true;
      _showSpeedPill = true;
    });
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    widget.controller.setRate(_rateBeforeBoost);
    _startHideTimer();
    setState(() {
      _longPressActive = false;
      _showSpeedPill = false;
    });
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
          // Persist the final position BEFORE the route pops so parent
          // screens reload with the save already committed.
          await _flushFinalProgress();
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The single-tap timer starts on tap UP (not down) so a long
            // press never fires the pending tap: TapGestureRecognizer is
            // rejected by the long-press recognizer before the pointer lifts.
            onTapUp: (details) {
              _singleTapTimer?.cancel();
              _singleTapTimer = Timer(const Duration(milliseconds: 250), () {
                if (_isSwiping || _longPressActive) return;
                _onScreenTap();
              });
            },
            onTapCancel: () => _singleTapTimer?.cancel(),
            onDoubleTapDown: (details) {
              _singleTapTimer?.cancel();
              _onDoubleTap(details);
            },
            onLongPressStart: _onLongPressStart,
            onLongPressEnd: _onLongPressEnd,
            onVerticalDragStart: _onVerticalDragStart,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // -- Video surface -------------------------------------------
                // The key includes subtitle state AND the zoom fit so the
                // widget rebuilds whenever either changes. It stays fully
                // mounted while Picture-in-Picture is active.
                Center(
                  child: Video(
                    key: ValueKey(
                      '$_subtitleOffset-$_subtitleOutline-$_subtitleFontSize-'
                      '$_subtitleBgOpacity-$_videoFit',
                    ),
                    controller: ctrl.videoController,
                    fit: _videoFit,
                    controls: (state) => const SizedBox.shrink(),
                    subtitleViewConfiguration: _buildSubtitleConfig(),
                  ),
                ),

                // -- Loading spinner -----------------------------------------
                _buildBufferingOverlay(ctrl),

                // In PiP mode the system renders a minimal floating window —
                // hide every overlay control (the video stays mounted).
                if (!_isInPip) ...[
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

                  // -- Long-press 2x speed pill ---------------------------------
                  _buildSpeedPillOverlay(),

                  // -- Overlay controls ----------------------------------------
                  IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControls(ctrl),
                  ),
                ],
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
  // Long-press 2x speed pill
  // ---------------------------------------------------------------------------

  Widget _buildSpeedPillOverlay() {
    return Positioned(
      top: 24,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: _showSpeedPill ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '2×',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(Icons.fast_forward, color: Colors.white, size: 18),
                ],
              ),
            ),
          ),
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
            onPressed: _exitPlayer,
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
          // Screenshot button
          IconButton(
            icon: const Icon(Icons.photo_camera, color: AppColors.textPrimary),
            tooltip: 'Screenshot',
            onPressed: _takeScreenshot,
          ),
          // Picture-in-Picture button (hidden when unavailable)
          if (_pipAvailable)
            IconButton(
              icon: const Icon(
                Icons.picture_in_picture_alt,
                color: AppColors.textPrimary,
              ),
              tooltip: 'Picture-in-Picture',
              onPressed: _enterPip,
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
          // Player settings button (tabbed sheet incl. subtitle settings)
          if (widget.contentId != null)
            IconButton(
              icon: const Icon(Icons.closed_caption,
                  color: AppColors.textPrimary),
              tooltip: 'Player settings',
              onPressed: _showPlayerSettings,
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

            const SizedBox(height: 14),

            // Quick-seek pills + playback speed chip
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                QuickSeekButton(
                  label: '-30s',
                  onPressed: () {
                    ctrl.seekBy(const Duration(seconds: -30));
                    _startHideTimer();
                  },
                ),
                const SizedBox(width: 8),
                QuickSeekButton(
                  label: '-10s',
                  onPressed: () {
                    ctrl.seekBy(const Duration(seconds: -10));
                    _startHideTimer();
                  },
                ),
                const SizedBox(width: 8),
                SpeedChip(rate: ctrl.rate, onTap: _showSpeedSelector),
                const SizedBox(width: 8),
                QuickSeekButton(
                  label: '+10s',
                  onPressed: () {
                    ctrl.seekBy(const Duration(seconds: 10));
                    _startHideTimer();
                  },
                ),
                const SizedBox(width: 8),
                QuickSeekButton(
                  label: '+30s',
                  onPressed: () {
                    ctrl.seekBy(const Duration(seconds: 30));
                    _startHideTimer();
                  },
                ),
              ],
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

  // ---------------------------------------------------------------------------
  // Player settings — tabbed bottom sheet
  // (Subtitles | Playback | Video | Audio | Advanced)
  // ---------------------------------------------------------------------------

  static const List<double> _speedPresets = [
    0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0, 4.0,
  ];

  String _formatRate(double rate) =>
      rate % 1 == 0 ? rate.toStringAsFixed(1) : rate.toString();

  String _formatDelay(double delay) {
    if (delay == 0) return '0.0s';
    return '${delay > 0 ? '+' : ''}${delay.toStringAsFixed(1)}s';
  }

  /// Opens the standalone playback speed selector (also used by the speed
  /// chip in the bottom control bar).
  Future<void> _showSpeedSelector() {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final rate = widget.controller.rate;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Playback Speed',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SettingsChipRow(
                      children: [
                        for (final speed in _speedPresets)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: SettingsChip(
                              label: '${_formatRate(speed)}×',
                              isSelected: (speed - rate).abs() < 0.001,
                              onTap: () {
                                widget.controller.setRate(speed);
                                _startHideTimer();
                              },
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showPlayerSettings() {
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
      builder: (sheetContext) {
        return DefaultTabController(
          length: 5,
          child: StatefulBuilder(
            builder: (context, setModalState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(top: 12, bottom: 8),
                      decoration: BoxDecoration(
                        color: AppColors.textSecondary.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelColor: AppColors.accentPrimary,
                    unselectedLabelColor: AppColors.textSecondary,
                    indicatorColor: AppColors.accentPrimary,
                    dividerColor: Colors.transparent,
                    tabs: [
                      Tab(text: 'Subtitles'),
                      Tab(text: 'Playback'),
                      Tab(text: 'Video'),
                      Tab(text: 'Audio'),
                      Tab(text: 'Advanced'),
                    ],
                  ),
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.4,
                    child: TabBarView(
                      children: [
                        _subtitlesTab(setModalState),
                        _playbackTab(setModalState),
                        _videoTab(setModalState),
                        _audioTab(setModalState),
                        _advancedTab(sheetContext, setModalState),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _settingsLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
          ),
        ),
      );

  // -- Subtitles tab (existing controls, preserved) ---------------------------

  Widget _subtitlesTab(StateSetter setModalState) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
  }

  // -- Playback tab ------------------------------------------------------------

  Widget _playbackTab(StateSetter setModalState) {
    final ctrl = widget.controller;
    final remaining = _sleepRemainingText;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _settingsLabel('Speed'),
            SettingsChipRow(
              children: [
                for (final speed in _speedPresets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SettingsChip(
                      label: '${_formatRate(speed)}×',
                      isSelected: (speed - ctrl.rate).abs() < 0.001,
                      onTap: () {
                        ctrl.setRate(speed);
                        setModalState(() {});
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _delayControl(
              label: 'Audio Delay',
              value: ctrl.audioDelay,
              onChanged: (v) => ctrl.setAudioDelay(v),
              setModalState: setModalState,
            ),
            const SizedBox(height: 20),
            _settingsLabel(
              remaining == null ? 'Sleep Timer' : 'Sleep Timer — $remaining left',
            ),
            SettingsChipRow(
              children: [
                for (final minutes in const [0, 15, 30, 45, 60, 90])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SettingsChip(
                      label: minutes == 0 ? 'Off' : '$minutes min',
                      isSelected: _isSleepTimerSelected(minutes),
                      onTap: () {
                        _setSleepTimer(minutes);
                        setModalState(() {});
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  bool _isSleepTimerSelected(int minutes) {
    final endsAt = _sleepEndsAt;
    if (minutes == 0) return endsAt == null;
    if (endsAt == null) return false;
    final target = DateTime.now().add(Duration(minutes: minutes));
    // "Selected" if the timer ends within ±30 s of this preset's window.
    return endsAt.difference(target).abs() < const Duration(seconds: 30);
  }

  // -- Video tab ---------------------------------------------------------------

  Widget _videoTab(StateSetter setModalState) {
    final ctrl = widget.controller;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _settingsLabel('Aspect Ratio'),
            SettingsChipRow(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SettingsChip(
                    label: 'Auto',
                    isSelected: ctrl.aspectOverride == null,
                    onTap: () {
                      ctrl.setAspectRatio(null);
                      setModalState(() {});
                    },
                  ),
                ),
                for (final preset in PlayerController.aspectPresets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SettingsChip(
                      label: preset,
                      isSelected: ctrl.aspectOverride == preset,
                      onTap: () {
                        ctrl.setAspectRatio(preset);
                        setModalState(() {});
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _settingsLabel('Rotation'),
            SettingsChipRow(
              children: [
                for (final degrees in const [0, 90, 180, 270])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SettingsChip(
                      label: '$degrees°',
                      isSelected: ctrl.rotation == degrees,
                      onTap: () {
                        ctrl.setRotation(degrees);
                        setModalState(() {});
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _settingsLabel('Zoom Fit'),
            SettingsChipRow(
              children: [
                for (final fit in const {
                  'Contain': BoxFit.contain,
                  'Cover': BoxFit.cover,
                  'Fill': BoxFit.fill,
                }.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SettingsChip(
                      label: fit.key,
                      isSelected: _videoFit == fit.value,
                      onTap: () {
                        setState(() => _videoFit = fit.value);
                        setModalState(() {});
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            SwitchListTile(
              title: const Text('Deinterlace',
                  style: TextStyle(color: AppColors.textPrimary)),
              subtitle: const Text('Improves quality of interlaced sources',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              value: ctrl.deinterlace,
              onChanged: (v) {
                ctrl.setDeinterlace(v);
                setModalState(() {});
              },
              activeThumbColor: AppColors.accentPrimary,
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // -- Audio tab ---------------------------------------------------------------

  Widget _audioTab(StateSetter setModalState) {
    final ctrl = widget.controller;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _settingsLabel('Volume Boost: ${ctrl.volume.round()}%'),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppColors.accentPrimary,
                inactiveTrackColor: AppColors.bgSurface,
                thumbColor: AppColors.accentPrimary,
                overlayColor: AppColors.accentPrimary.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: ctrl.volume.clamp(0.0, PlayerController.maxVolumePercent),
                min: 0.0,
                max: PlayerController.maxVolumePercent,
                divisions: 40,
                onChanged: (v) {
                  ctrl.setVolumeBoostPercent(v);
                  setModalState(() {});
                },
              ),
            ),
            const Text(
              '(>100% may distort)',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 20),
            _delayControl(
              label: 'Subtitle Delay',
              value: ctrl.subDelay,
              onChanged: (v) => ctrl.setSubDelay(v),
              setModalState: setModalState,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // -- Advanced tab ------------------------------------------------------------

  Widget _advancedTab(BuildContext sheetContext, StateSetter setModalState) {
    final ctrl = widget.controller;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _settingsLabel('Buffer Size'),
            SettingsChipRow(
              children: [
                for (final mb in const [16, 64, 150])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SettingsChip(
                      label: '$mb MB',
                      isSelected: ctrl.bufferMb == mb,
                      onTap: () {
                        ctrl.setBufferMegabytes(mb);
                        setModalState(() {});
                      },
                    ),
                  ),
              ],
            ),
            const Text(
              'Larger buffers smooth out unstable streams but increase '
              'time to start / seek. Applies to the next stream opened.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 20),
            _settingsLabel('Screenshot'),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _takeScreenshot();
              },
              icon: const Icon(Icons.photo_camera),
              label: const Text('Capture & Share'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentPrimary,
                foregroundColor: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// -- Shared delay control (-0.5s / +0.5s / reset) ---------------------------

  Widget _delayControl({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    required StateSetter setModalState,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsLabel('$label: ${_formatDelay(value)}'),
        SettingsChipRow(
          children: [
            SettingsChip(
              label: '-0.5s',
              isSelected: false,
              onTap: () {
                onChanged(
                  double.parse((value - 0.5).toStringAsFixed(1)),
                );
                setModalState(() {});
              },
            ),
            const SizedBox(width: 8),
            SettingsChip(
              label: '+0.5s',
              isSelected: false,
              onTap: () {
                onChanged(
                  double.parse((value + 0.5).toStringAsFixed(1)),
                );
                setModalState(() {});
              },
            ),
            const SizedBox(width: 8),
            SettingsChip(
              label: 'Reset',
              isSelected: false,
              onTap: () {
                onChanged(0.0);
                setModalState(() {});
              },
            ),
          ],
        ),
      ],
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
