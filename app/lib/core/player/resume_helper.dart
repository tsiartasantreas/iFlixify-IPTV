import 'dart:async';

import 'player_controller.dart';

/// Drives "resume from saved position" for both [PlayerScreen] and
/// [TvPlayerScreen] as a single, timer-based state machine (250 ms poll, not
/// tied to player stream events).
///
/// Failure modes this machine is designed against:
///
/// - **Seeks racing the load**: a seek issued before mpv finished opening the
///   playback chain is silently dropped. The seek is therefore only issued
///   once a trustworthy duration is known, and is re-issued until the
///   position actually reaches the target.
/// - **Partial durations (HLS)**: mpv can report a small initial duration
///   (first segments only) before the full duration arrives. Seeking past a
///   partial duration clamps to EOF and marks the media completed — the
///   machine waits until the reported duration covers the target (clamping
///   the target as a last resort) before seeking.
/// - **media_kit `play()` restarts from zero** when it believes the media has
///   completed (`state.completed` → `seek(Duration.zero)`). `play()` is
///   therefore only called after the seek has been verified, and never
///   repeatedly alongside seeks.
/// - **Stuck-paused give-up**: if the resume can never be verified, the
///   machine gives up and calls `play()` from the current position — the
///   player must never be left paused forever.
///
/// Every step is logged with the `[Resume]` tag to make field diagnosis of
/// the exact failing stage possible.
class ResumeHelper {
  ResumeHelper({
    required this._controller,
    required this._target,
    this.tag = '[Resume]',
  });

  static const Duration _pollInterval = Duration(milliseconds: 250);

  /// How long a freshly issued seek has to move the position to the target
  /// before it is considered dropped and re-issued.
  static const Duration _verifyWindow = Duration(seconds: 3);

  /// How long to wait for the reported duration to grow past the target
  /// before clamping the target to the reported duration.
  static const Duration _shortDurationGrace = Duration(seconds: 8);

  /// Maximum number of seek (re-)issues before giving up.
  static const int _maxSeekAttempts = 20;

  /// Maximum number of 250 ms polls to wait for ANY duration before giving
  /// up (120 polls = 30 s — e.g. a dead stream that never loads).
  static const int _maxDurationWaitPolls = 120;

  final PlayerController _controller;
  final String tag;

  /// Resume target. May be clamped down to the reported duration if the
  /// media never reports a duration covering the original target.
  Duration _target;

  Timer? _pollTimer;
  bool _active = false;
  bool _succeeded = false;

  /// Whether the (first) seek has been issued for the current media load.
  bool _seekIssued = false;
  DateTime? _seekIssuedAt;
  int _seekAttempts = 0;
  int _durationWaitPolls = 0;
  DateTime? _shortDurationSince;

  /// True while the resume has not yet been verified or abandoned. While
  /// active, the owning screen must suppress watch-progress saving (the
  /// position would still be ~0 and clobber the saved progress) and must not
  /// let the user un-pause the player.
  bool get isActive => _active;

  /// True when the resume was verified (the position reached the target).
  bool get succeeded => _succeeded;

  /// Starts the poll loop. Safe to call more than once.
  void start() {
    if (_active) return;
    _active = true;
    // ignore: avoid_print
    print('$tag start target=${_target.inSeconds}s');
    _pollTimer = Timer.periodic(_pollInterval, (_) => _tick());
  }

  /// Stops the loop without any playback side effects (used on dispose).
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _active = false;
  }

  void _tick() {
    if (!_active) return;
    final duration = _controller.duration;

    // A duration reset to zero means the media was (re)opened (e.g. the user
    // hit Retry on the error overlay) — re-arm the seek for the new load.
    if (_seekIssued && duration <= Duration.zero) {
      // ignore: avoid_print
      print('$tag duration reset — media re-opened, re-arming seek');
      _seekIssued = false;
      _seekIssuedAt = null;
    }

    // Phase 1: wait until the media reports a duration at all.
    if (duration <= Duration.zero) {
      _durationWaitPolls++;
      if (_durationWaitPolls >= _maxDurationWaitPolls) {
        // ignore: avoid_print
        print('$tag no duration after 30s — giving up (unreachable stream?)');
        _finish(success: false);
      }
      return;
    }

    // Phase 2: guard against a partial duration that does not yet cover the
    // target. Seeking past the reported duration would clamp to EOF and make
    // mpv mark the media completed (which media_kit's play() answers with a
    // restart from zero). Wait up to 8 s for the full duration; if it never
    // grows, clamp the target to the reported duration.
    if (duration + const Duration(seconds: 2) < _target) {
      _shortDurationSince ??= DateTime.now();
      final waited = DateTime.now().difference(_shortDurationSince!);
      if (waited < _shortDurationGrace) {
        return; // Keep waiting for the full duration to arrive.
      }
      final clamped =
          Duration(milliseconds: (duration.inMilliseconds * 0.98).round());
      // ignore: avoid_print
      print('$tag duration still short (${duration.inSeconds}s) after '
          '${waited.inSeconds}s — clamping target to ${clamped.inSeconds}s');
      _target = clamped;
    } else {
      _shortDurationSince = null;
    }

    // Phase 3: issue the seek exactly once for this media load.
    if (!_seekIssued) {
      _seekIssued = true;
      _seekIssuedAt = DateTime.now();
      // ignore: avoid_print
      print('$tag duration ready ${duration.inSeconds}s');
      // ignore: avoid_print
      print('$tag seek issued → ${_target.inSeconds}s (paused)');
      _controller.seek(_target);
      return;
    }

    // Phase 4: verify the seek actually landed. The position must reach the
    // target (minus a 2 s tolerance) within the verify window. The explicit
    // `position > Duration.zero` check prevents a false success at position
    // 0 for tiny targets.
    final position = _controller.position;
    final reached = position >= _target - const Duration(seconds: 2) &&
        (position > Duration.zero ||
            _target <= const Duration(seconds: 2));
    if (reached) {
      // ignore: avoid_print
      print('$tag verified at ${position.inSeconds}s');
      _finish(success: true);
      return;
    }

    final elapsed = DateTime.now().difference(_seekIssuedAt!);
    if (elapsed >= _verifyWindow) {
      _seekAttempts++;
      if (_seekAttempts >= _maxSeekAttempts) {
        // ignore: avoid_print
        print('$tag giving up after $_seekAttempts seek attempts — '
            'playing from current position');
        _finish(success: false);
        return;
      }
      // ignore: avoid_print
      print('$tag seek not applied (pos=${position.inSeconds}s, '
          'duration=${duration.inSeconds}s) — re-issuing '
          '(attempt $_seekAttempts/$_maxSeekAttempts)');
      _seekIssuedAt = DateTime.now();
      _controller.seek(_target);
    }
  }

  /// Ends the machine. Always ensures the player is playing afterwards so a
  /// failed resume can never leave the user stuck on a paused black frame.
  void _finish({required bool success}) {
    _succeeded = success;
    _active = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_controller.isPlaying) {
      // ignore: avoid_print
      print('$tag playing');
      _controller.play();
    }
  }
}
