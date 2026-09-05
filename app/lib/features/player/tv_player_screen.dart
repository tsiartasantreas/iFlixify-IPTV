import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
// wakelock_plus is a transitive dependency (via media_kit_video); it is used
// directly here for keep-screen-on during playback. The ignore silences the
// depend_on_referenced_packages lint until it is promoted to a direct dep.
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/data/database.dart';
import '../../core/data/watch_progress_service.dart';
import '../../core/player/player_controller.dart';
import '../../core/player/resume_helper.dart';
import '../../core/theme/app_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/data/offline_download_service.dart';
import '../../core/widgets/favorite_button.dart';
import 'widgets/player_overlay_widgets.dart';
import 'widgets/tv_settings_dialog.dart';

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

  /// Shared resume-from-saved-position state machine (see [ResumeHelper]).
  /// Null when there is nothing to resume. While `isActive`, progress is NOT
  /// saved — the position would be ~0 and would clobber the very progress we
  /// are resuming from — and the user cannot un-pause the player.
  ResumeHelper? _resume;

  /// True while the saved [TvPlayerScreen.startPosition] has not yet been
  /// applied and verified on the player.
  bool get _resumePending => _resume?.isActive ?? false;
  bool _completed = false;
  EpisodeUpNext? _upNext;

  /// True when watch progress should be recorded for this session.
  bool get _recordsProgress =>
      widget.contentId != null && widget.contentId!.isNotEmpty && !widget.isLive;

  // -- Subtitle preferences --------------------------------------------------
  double _subtitleFontSize = 18.0;
  double _subtitleBgOpacity = 0.6;
  double _subtitleOffset = 0.0;
  bool _subtitleOutline = true;

  // -- Long-press OK => temporary 2x speed ------------------------------------
  /// Pending timer that fires the temporary 2x boost while OK is held.
  Timer? _longPressTimer;
  bool _selectKeyDown = false;
  bool _longPressFired = false;
  bool _tempBoostActive = false;
  double _rateBeforeTempBoost = 1.0;

  // -- Sleep timer -------------------------------------------------------------
  Timer? _sleepTicker;
  Duration _sleepRemaining = Duration.zero;

  // -- Focus plumbing for D-pad navigation -------------------------------------
  /// Enclosing (non-focusable) focus nodes for the top bar and the bottom
  /// action row; used to detect which overlay region the focus is in and to
  /// return focus to the video surface.
  final FocusNode _topBarNode = FocusNode();
  final FocusNode _bottomBarNode = FocusNode();

  static final Set<LogicalKeyboardKey> _activateKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };

  @override
  void initState() {
    super.initState();
    _startHideTimer();

    // Keep the screen awake while the player is open.
    WakelockPlus.enable();

    if (_recordsProgress) {
      _watchService = WatchProgressService(database: AppDatabase());
      // Save progress every 10 seconds while the player is open.
      _progressTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _saveWatchProgress(),
      );
      widget.controller.addListener(_onPlayerChanged);
    }
    if (widget.startPosition != null &&
        widget.startPosition! > Duration.zero) {
      // Opened paused (the caller used open(autoPlay: false)); start the
      // resume state machine. It waits for a trustworthy duration, seeks
      // once, verifies the seek landed, and only then calls play(). While
      // it is active, watch-progress saving is suppressed (see
      // [_saveWatchProgress]) and manual play/pause is gated.
      //
      // NOTE: deliberately NOT nested inside the `_recordsProgress` block —
      // a paused open MUST always get a resume driver, otherwise the player
      // would sit paused forever with no timeout armed and no way to detect
      // the stalled load.
      _resume = ResumeHelper(
        controller: widget.controller,
        target: widget.startPosition!,
        tag: '[Resume]',
      )..start();
    }
    if (_recordsProgress) {
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
    _longPressTimer?.cancel();
    _sleepTicker?.cancel();
    _topBarNode.dispose();
    _bottomBarNode.dispose();
    WakelockPlus.disable();
    _resume?.dispose();
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

  /// Reacts to player state changes: pause save, completion.
  void _onPlayerChanged() {
    final ctrl = widget.controller;

    // The resume state machine ([ResumeHelper]) polls the controller on its
    // own timer; nothing resume-related needs to happen on notifications.

    // Treat >= 95% watched as completed: drop from Continue Watching.
    // Skipped while the resume is pending — the player is parked at the
    // resume point and progress must not be cleared mid-resume.
    if (!_completed &&
        !_resumePending &&
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
    final ctrl = widget.controller;
    final primary = FocusManager.instance.primaryFocus;
    final onSurface = primary == node;

    // -- Focus is on an overlay control (top bar / bottom bar) ----------------
    // Let the control's own handlers and the default focus traversal do the
    // work; only step in to return focus to the video surface and to keep
    // Back/Escape exiting the player.
    if (!onSurface) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowDown:
          if (primary!.ancestors.contains(_bottomBarNode)) {
            node.requestFocus();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;

        case LogicalKeyboardKey.arrowUp:
          if (primary!.ancestors.contains(_topBarNode)) {
            node.requestFocus();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;

        // Back / Escape => exit player (same as on the video surface).
        case LogicalKeyboardKey.goBack:
        case LogicalKeyboardKey.escape:
          _exitPlayer();
          return KeyEventResult.handled;

        default:
          return KeyEventResult.ignored;
      }
    }

    // -- Focus is on the video surface ----------------------------------------

    // OK released: either end the temporary 2x boost, or (quick press) toggle
    // play/pause.
    if (event is KeyUpEvent) {
      if (_activateKeys.contains(event.logicalKey)) {
        _onSurfaceSelectReleased();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      // Center / Select / Enter / Space / Gamepad A
      // Quick press => toggle play/pause; held >= 600 ms => temporary 2x.
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.gameButtonA:
        if (event is KeyDownEvent) {
          _onSurfaceSelectPressed();
        }
        // Swallow key repeats while OK is held.
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
        _exitPlayer();
        return KeyEventResult.handled;

      default:
        return KeyEventResult.ignored;
    }
  }

  // ---------------------------------------------------------------------------
  // Long-press OK => temporary 2x speed
  // ---------------------------------------------------------------------------

  /// Called on OK KeyDownEvent on the video surface. Starts the 600 ms
  /// long-press timer; a quick release before it fires toggles play/pause.
  void _onSurfaceSelectPressed() {
    _selectKeyDown = true;
    _longPressFired = false;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 600), () {
      if (!_selectKeyDown || !mounted) return;
      _longPressFired = true;
      _rateBeforeTempBoost = widget.controller.rate;
      _tempBoostActive = true;
      widget.controller.setRate(2.0);
      if (mounted) setState(() {});
    });
  }

  /// Called on OK KeyUpEvent on the video surface.
  void _onSurfaceSelectReleased() {
    if (!_selectKeyDown) return;
    _selectKeyDown = false;
    _longPressTimer?.cancel();
    _longPressTimer = null;

    if (_longPressFired) {
      // Long press fired: restore the previous playback rate.
      _longPressFired = false;
      if (_tempBoostActive) {
        _tempBoostActive = false;
        widget.controller.setRate(_rateBeforeTempBoost);
        if (mounted) setState(() {});
      }
      return;
    }

    // Quick press: toggle play/pause (original behavior) — but never
    // un-pause while the resume seek is still pending.
    if (!_resumePending) widget.controller.togglePlay();
    _showControls();
  }

  // ---------------------------------------------------------------------------
  // Sleep timer
  // ---------------------------------------------------------------------------

  /// Starts (or cancels, when [minutes] is 0) the sleep timer. When it hits
  /// zero, playback is paused and a toast is shown.
  void _setSleepTimer(int minutes) {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    if (minutes <= 0) {
      if (mounted) setState(() => _sleepRemaining = Duration.zero);
      return;
    }
    if (mounted) setState(() => _sleepRemaining = Duration(minutes: minutes));
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (ticker) {
      if (!mounted) {
        ticker.cancel();
        return;
      }
      setState(() {
        _sleepRemaining -= const Duration(seconds: 1);
      });
      if (_sleepRemaining <= Duration.zero) {
        ticker.cancel();
        _sleepTicker = null;
        setState(() => _sleepRemaining = Duration.zero);
        widget.controller.pause();
        _showToast('Sleep timer finished — playback paused');
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Screenshot
  // ---------------------------------------------------------------------------

  Future<void> _takeScreenshot() async {
    _showControls();
    final bytes = await widget.controller.takeScreenshot();
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      _showToast('Screenshot failed');
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
      if (!mounted) return;
      _showToast('Screenshot saved');
    } catch (_) {
      // File writing / sharing unavailable — degrade gracefully.
      if (!mounted) return;
      _showToast('Screenshot captured (${bytes.length} bytes)');
    }
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Settings dialog
  // ---------------------------------------------------------------------------

  /// Opens the extended TV settings dialog, restoring focus to whatever was
  /// focused before it opened (falls back to the video surface).
  Future<void> _openSettingsDialog(TvSettingsTab initialTab) async {
    _showControls();
    final previousFocus = FocusManager.instance.primaryFocus;
    await showTvSettingsDialog(
      context,
      controller: widget.controller,
      initialTab: initialTab,
      subtitleFontSize: _subtitleFontSize,
      subtitleBgOpacity: _subtitleBgOpacity,
      subtitleOffset: _subtitleOffset,
      subtitleOutline: _subtitleOutline,
      onSubtitleFontSize: _setSubtitleFontSize,
      onSubtitleBgOpacity: _setSubtitleBgOpacity,
      onSubtitleOffset: _setSubtitleOffset,
      onSubtitleOutline: _setSubtitleOutline,
      sleepRemaining: _sleepRemaining,
      onSelectSleepTimer: _setSleepTimer,
    );
    if (mounted) {
      (previousFocus ?? _focusNode).requestFocus();
      _startHideTimer();
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
        // Persist the final position BEFORE the route pops so parent
        // screens reload with the save already committed.
        await _flushFinalProgress();
        if (context.mounted) Navigator.of(context).pop();
      },
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

              // -- Temporary 2x speed pill (long-press OK) --------------------
              if (_tempBoostActive)
                const Positioned(
                  top: 16,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: _TempSpeedPill(),
                    ),
                  ),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  color: AppColors.accentPrimary,
                ),
                SizedBox(height: 16),
                Text(
                  'Buffering…',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
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
              Focus(
                canRequestFocus: false,
                focusNode: _topBarNode,
                child: FocusTraversalGroup(
                  child: _buildTopBar(ctrl),
                ),
              ),

              const Spacer(),

              // -- Center: play/pause + next/prev ----------------------------
              _buildCenterArea(ctrl),

              // -- Bottom: progress bar + timestamps + D-pad hints -----------
              _buildProgressBarArea(ctrl),

              // -- Bottom action row: speed / seek / sleep --------------------
              Focus(
                canRequestFocus: false,
                focusNode: _bottomBarNode,
                child: FocusTraversalGroup(
                  child: _buildBottomActionRow(ctrl),
                ),
              ),
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
          // Screenshot button
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _TvIconButton(
              icon: Icons.photo_camera,
              tooltip: 'Screenshot',
              onPressed: _takeScreenshot,
            ),
          ),
          // Settings / playback speed button
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _TvIconButton(
              icon: Icons.speed,
              tooltip: 'Playback settings',
              onPressed: () =>
                  _openSettingsDialog(TvSettingsTab.playback),
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
          // Subtitle settings button (opens the TV settings dialog)
          if (widget.contentId != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _TvIconButton(
                icon: Icons.closed_caption,
                tooltip: 'Subtitle settings',
                onPressed: () =>
                    _openSettingsDialog(TvSettingsTab.subtitles),
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

  /// Bottom action row: speed chip, -30s/+30s seek, sleep-timer indicator.
  Widget _buildBottomActionRow(PlayerController ctrl) {
    final sleepActive = _sleepRemaining > Duration.zero;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TvFocusChip(
            label: formatTvRate(ctrl.rate),
            accentWhenActive: (ctrl.rate - 1.0).abs() > 0.01,
            onActivated: () => _openSettingsDialog(TvSettingsTab.playback),
          ),
          const SizedBox(width: 12),
          TvFocusChip(
            label: '-30s',
            onActivated: () {
              ctrl.seekBy(const Duration(seconds: -30));
              _showControls();
            },
          ),
          const SizedBox(width: 12),
          TvFocusChip(
            label: '+30s',
            onActivated: () {
              ctrl.seekBy(const Duration(seconds: 30));
              _showControls();
            },
          ),
          if (sleepActive) ...[
            const SizedBox(width: 12),
            TvFocusChip(
              label: 'Sleep '
                  '${_sleepRemaining.inMinutes.toString().padLeft(2, '0')}:'
                  '${_sleepRemaining.inSeconds.remainder(60).toString().padLeft(2, '0')}',
              accentWhenActive: true,
              onActivated: () => _openSettingsDialog(TvSettingsTab.playback),
            ),
          ],
        ],
      ),
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

  // The subtitle styling controls live in the extended TV settings dialog
  // (Subtitles tab, see widgets/tv_settings_dialog.dart). These setters mutate
  // the screen state and persist to SharedPreferences, exactly like the old
  // standalone dialog did; the `Video` ValueKey rebuilds with the new style.

  Future<void> _setSubtitleFontSize(double size) async {
    setState(() {
      _subtitleFontSize = size;
      _applySubtitleStyle();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('subtitle_font_size', size);
  }

  Future<void> _setSubtitleBgOpacity(double opacity) async {
    setState(() {
      _subtitleBgOpacity = opacity;
      _applySubtitleStyle();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('subtitle_bg_opacity', opacity);
  }

  Future<void> _setSubtitleOffset(double offset) async {
    setState(() {
      _subtitleOffset = offset;
      _applySubtitlePosition(offset);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('subtitle_offset', offset);
  }

  Future<void> _setSubtitleOutline(bool outline) async {
    setState(() {
      _subtitleOutline = outline;
      _applySubtitleStyle();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('subtitle_outline', outline);
  }
}

/// Accent pill shown while the long-press-OK temporary 2x boost is active.
class _TempSpeedPill extends StatelessWidget {
  const _TempSpeedPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.accentPrimary.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fast_forward, color: AppColors.textPrimary, size: 18),
          SizedBox(width: 8),
          Text(
            '2× Speed',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
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
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
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
