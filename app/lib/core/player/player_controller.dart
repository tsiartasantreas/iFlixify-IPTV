import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:iflixify/core/player/player_config.dart';

/// Wraps [media_kit]'s [Player] for the Flixium video/audio surface.
///
/// Exposes reactive state via [ChangeNotifier] so both mobile and TV player
/// screens can rebuild on position / playback / buffering changes.
///
/// Usage:
/// ```dart
/// await PlayerController.ensureInitialized();
/// final ctrl = PlayerController();
/// await ctrl.open('https://stream.example.com/live.m3u8');
/// // …
/// ctrl.dispose();
/// ```
class PlayerController extends ChangeNotifier {
  /// Create a standalone controller (default) or supply an existing [Player]
  /// for tests that need to mock the underlying playback engine.
  PlayerController({Player? player}) {
    _player = player ?? Player();
    _videoController = VideoController(_player);
    _positionSub = _player.stream.position.listen((p) {
      _position = p;
      // Real playback progress: playing flag up AND the position actually
      // advanced past zero. See [_everPlayed] for why this distinction
      // matters (media_kit's optimistic playing events).
      if (_isPlaying && p > Duration.zero) {
        _everPlayed = true;
      }
      notifyListeners();
    });
    _durationSub = _player.stream.duration.listen((d) {
      _duration = d;
      notifyListeners();
    });
    _playingSub = _player.stream.playing.listen((p) {
      _isPlaying = p;
      if (p) {
        if (_position > Duration.zero) {
          _everPlayed = true;
        }
        // Clear any stale error / buffering state that may have been set by
        // a non-fatal codec warning before the first frame decoded.
        //
        // NOTE: the startup timeout is deliberately NOT cancelled here.
        // media_kit emits `playing = true` optimistically as soon as mpv is
        // un-paused, before a single byte of the stream may have arrived —
        // cancelling on that event made the 15 s dead-stream timeout
        // unreachable. The timer now only fires when no real playback
        // progress has been seen (see [_everPlayed] and [_armStartupTimeout]).
        _error = null;
        _isBuffering = false;
      }
      notifyListeners();
    });
    _bufferingSub = _player.stream.buffering.listen((b) {
      _isBuffering = b;
      notifyListeners();
    });
    _errorSub = _player.stream.error.listen((msg) {
      // Case 1 — player not playing at all (paused / paused-for-resume /
      // idle): nothing to lose, surface immediately.
      if (!_player.state.playing) {
        _pendingErrorTimer?.cancel();
        _pendingError = null;
        _surfaceError(msg);
        return;
      }

      // Case 2 — real playback already in progress (`_everPlayed`): some
      // codecs (e.g. AVI / DivX) emit non-fatal warnings during
      // hardware-decode fallback while playback continues fine in the
      // background. These are benign and must not surface to the UI.
      if (_everPlayed) {
        // ignore: avoid_print
        print('[PlayerEngine] non-fatal warning while playing (ignored): '
            '$msg');
        return;
      }

      // Case 3 — load window: media_kit has already flipped its optimistic
      // `playing = true` flag, but no frame has decoded yet. The error may
      // be a fatal dead-stream failure OR a benign pre-first-frame decoder
      // warning. Defer the decision by a short grace window: if real
      // playback starts, discard the warning; if not, surface it.
      // ignore: avoid_print
      print('[PlayerEngine] error during load window — deferring: $msg');
      _pendingError = msg;
      _pendingErrorTimer?.cancel();
      _pendingErrorTimer = Timer(const Duration(seconds: 5), () {
        if (_everPlayed) {
          // ignore: avoid_print
          print('[PlayerEngine] deferred error discarded — playback started '
              'after all: $_pendingError');
        } else {
          _surfaceError(_pendingError ?? msg);
        }
        _pendingError = null;
      });
    });

    // -- Track streams (audio / subtitle / video) ----------------------------
    _tracksSub = _player.stream.tracks.listen((t) {
      _audioTracks = t.audio;
      _subtitleTracks = t.subtitle;
      _videoTracks = t.video;
      notifyListeners();
    });
    _trackSub = _player.stream.track.listen((t) {
      _currentAudioTrack = t.audio;
      _currentSubtitleTrack = t.subtitle;
      notifyListeners();
    });

    // -- Volume stream -------------------------------------------------------
    _volumeSub = _player.stream.volume.listen((v) {
      _volume = v;
      notifyListeners();
    });
  }

  /// Call once before first use. Must run after
  /// `WidgetsFlutterBinding.ensureInitialized()`.
  static Future<void> ensureInitialized() async {
    MediaKit.ensureInitialized();
  }

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  late final Player _player;
  late final VideoController _videoController;

  /// Current player configuration, updated on each [open] call.
  PlayerConfig _currentConfig = PlayerConfig.defaultConfig;

  /// Returns the configuration active on the current stream.
  PlayerConfig get currentConfig => _currentConfig;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isBuffering = false;

  /// True once the engine has shown REAL playback progress: the playing
  /// flag is up AND the position has actually advanced past zero.
  ///
  /// media_kit emits `playing = true` optimistically the moment `open(play:
  /// true)` / `play()` un-pauses mpv — long before any frame is decoded or
  /// any byte arrives. That optimistic event must NOT be mistaken for real
  /// playback: the startup timeout is only considered satisfied (and codec
  /// warnings are only treated as benign) once [Player.position] has moved.
  bool _everPlayed = false;

  /// Last error message from the player, if any.
  String? _error;

  /// An error that arrived during the load window (media_kit's optimistic
  /// `playing = true`, no frame decoded yet). Surfaced only if real playback
  /// does not start within the grace window — see [_errorSub].
  String? _pendingError;
  Timer? _pendingErrorTimer;

  /// Stored for [retry].
  String? _lastUrl;
  PlayerConfig? _lastConfig;

  /// Fires if playback does not start within the timeout window.
  Timer? _timeoutTimer;

  /// Whether the startup timeout is currently scheduled. While resuming from
  /// a saved position the player is opened paused (`autoPlay: false`); the
  /// timeout must NOT run while paused-for-resume — it is armed by the first
  /// [play] call instead (see [_armStartupTimeout]).
  bool _timeoutArmed = false;

  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration> _durationSub;
  late final StreamSubscription<bool> _playingSub;
  late final StreamSubscription<bool> _bufferingSub;
  late final StreamSubscription<String> _errorSub;

  // -- Track state -----------------------------------------------------------
  late final StreamSubscription<Tracks> _tracksSub;
  late final StreamSubscription<Track> _trackSub;

  List<AudioTrack> _audioTracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  List<VideoTrack> _videoTracks = [];

  AudioTrack _currentAudioTrack = AudioTrack.no();
  SubtitleTrack _currentSubtitleTrack = SubtitleTrack.no();

  // -- Volume state ----------------------------------------------------------
  late final StreamSubscription<double> _volumeSub;
  double _volume = 100.0;

  /// True once `volume-max` has been raised to 200 via [setVolumeBoostPercent].
  bool _volumeMaxRaised = false;

  // -- VLC-grade playback state ---------------------------------------------

  /// Playback rate (persistent across [open] calls on purpose).
  double _rate = 1.0;

  /// Audio delay in seconds (negative = earlier). Reset on every [open].
  double _audioDelay = 0.0;

  /// Subtitle delay in seconds (negative = earlier). Reset on every [open].
  double _subDelay = 0.0;

  /// Aspect-ratio override preset, or null when off. Reset on every [open].
  String? _aspectOverride;

  /// Video rotation in degrees (0/90/180/270). Reset on every [open].
  int _rotation = 0;

  /// Whether deinterlacing is enabled. Reset on every [open].
  bool _deinterlace = false;

  /// Demuxer buffer size in megabytes. Persisted across [open] calls.
  int _bufferMb = 64;

  /// Whether the audio equalizer feature is usable on this platform/engine.
  ///
  /// The installed media_kit (1.2.6) does not ship an `Equalizer` API, so this
  /// is `false` and [setEqualizerPreset] is a no-op. Kept non-final so a
  /// future engine upgrade can flip it at runtime.
  // ignore: prefer_final_fields
  bool _equalizerAvailable = false;

  /// Currently selected equalizer preset name, or null (Flat / disabled).
  String? _equalizerPreset;

  // ---------------------------------------------------------------------------
  // Public API — read-only properties
  // ---------------------------------------------------------------------------

  /// The underlying [Player] instance (for [VideoController] creation, etc.).
  Player get player => _player;

  /// The [VideoController] to pass to [Video] widgets.
  VideoController get videoController => _videoController;

  /// Current playback position.
  Duration get position => _position;

  /// Total duration of the current media.
  Duration get duration => _duration;

  /// Whether playback is active.
  bool get isPlaying => _isPlaying;

  /// Whether the player is currently buffering.
  bool get isBuffering => _isBuffering;

  /// True when duration is known and positive (not live).
  bool get hasDuration => _duration > Duration.zero;

  /// Formatted position string `mm:ss`.
  String get positionText => _formatDuration(_position);

  /// Formatted duration string `mm:ss` or `"LIVE"` when unknown.
  String get durationText =>
      _duration > Duration.zero ? _formatDuration(_duration) : 'LIVE';

  /// Seek fraction in [0, 1] — useful for seek-bar sliders.
  double get seekFraction {
    if (_duration <= Duration.zero) return 0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Non-null when the current stream has failed.
  String? get error => _error;

  /// Convenience flag for UI layers.
  bool get hasError => _error != null;

  // -- Track getters ---------------------------------------------------------

  /// Available audio tracks for the current media.
  List<AudioTrack> get audioTracks => _audioTracks;

  /// Available subtitle tracks for the current media.
  List<SubtitleTrack> get subtitleTracks => _subtitleTracks;

  /// Available video tracks (quality levels) for the current media.
  List<VideoTrack> get videoTracks => _videoTracks;

  /// Currently active audio track.
  AudioTrack get currentAudioTrack => _currentAudioTrack;

  /// Currently active subtitle track.
  SubtitleTrack get currentSubtitleTrack => _currentSubtitleTrack;

  /// Whether multiple audio tracks are available.
  bool get hasMultipleAudioTracks => _audioTracks.length > 1;

  /// Whether any subtitle tracks are available (excluding "none").
  bool get hasSubtitleTracks =>
      _subtitleTracks.where((t) => t != SubtitleTrack.no()).isNotEmpty;

  /// Human-readable label for the current video resolution.
  /// Returns e.g. "1920x1080" or empty string if unknown.
  String get videoResolution {
    if (_videoTracks.isEmpty) return '';
    // Try the first video track for dimensions.
    final track = _videoTracks.first;
    final w = track.w;
    final h = track.h;
    if (w != null && h != null && w > 0 && h > 0) {
      return '${w}x$h';
    }
    return '';
  }

  // -- Volume getter/setter --------------------------------------------------

  /// Maximum volume in percent. Stays 100 until [setVolumeBoostPercent]
  /// raises the underlying mpv `volume-max` property to 200.
  static const double maxVolumePercent = 200.0;

  /// Current volume in the range [0, 100] normally, or [0, 200] once the
  /// volume boost has been enabled.
  double get volume => _volume;

  /// Set volume. [value] is clamped to [0, 100], or [0, 200] after
  /// [setVolumeBoostPercent] has raised `volume-max`.
  Future<void> setVolume(double value) async {
    final max = _volumeMaxRaised ? maxVolumePercent : 100.0;
    await _player.setVolume(value.clamp(0, max));
  }

  /// Volume as a fraction [0, 1] (convenient for slider widgets). Values
  /// above 100 clamp to 1.0 so existing UI sliders keep working unchanged.
  double get volumeFraction => (_volume / 100).clamp(0.0, 1.0);

  /// Set volume from a fraction [0, 1].
  Future<void> setVolumeFraction(double fraction) =>
      setVolume(fraction * 100);

  /// Enable soft volume boost and set the volume to [p] percent
  /// (clamped to [0, 200]). Raises the mpv `volume-max` property to 200
  /// exactly once, lazily, on first use.
  Future<void> setVolumeBoostPercent(double p) async {
    if (!_volumeMaxRaised) {
      _setProperty('volume-max', maxVolumePercent.toStringAsFixed(0));
      _volumeMaxRaised = true;
    }
    final clamped = p.clamp(0.0, maxVolumePercent).toDouble();
    try {
      await _player.setVolume(clamped);
    } catch (e) {
      debugPrint('[PlayerEngine] setVolumeBoostPercent($clamped) failed: $e');
    }
    _volume = clamped;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Public API — playback controls
  // ---------------------------------------------------------------------------

  /// Open a media URL (video, live stream, or audio-only).
  ///
  /// When [config] is provided, its HTTP headers are applied to the
  /// underlying [Media] object. MPV options (hwdec, protocol-whitelist, etc.)
  /// are applied to the underlying [Player] before the media is opened.
  ///
  /// If the stream does not begin playback within 15 seconds an error is set
  /// automatically. Call [retry] to re-open the same URL.
  Future<void> open(String url, {PlayerConfig? config, bool autoPlay = true}) async {
    // Clear any previous error.
    _error = null;
    _pendingErrorTimer?.cancel();
    _pendingError = null;
    // New media load: no real playback progress exists yet.
    _everPlayed = false;
    _lastUrl = url;
    _lastConfig = config ?? PlayerConfig.defaultConfig;
    _currentConfig = _lastConfig!;

    // -- Reset per-stream VLC-grade state (BEFORE _player.open) --------------
    // NOTE: _rate is intentionally NOT reset — it persists across opens.
    _audioDelay = 0.0;
    _subDelay = 0.0;
    _aspectOverride = null;
    _setProperty('video-aspect-override', 'no');
    _rotation = 0;
    _setProperty('video-rotate', '0');
    _deinterlace = false;
    _setProperty('deinterlace', 'no');
    // _bufferMb intentionally persists across opens.
    notifyListeners();

    // ignore: avoid_print
    print('[PlayerController] open() url=$url');
    // ignore: avoid_print
    print('[PlayerController] config: hwdec=${_currentConfig.hwdec}, '
        'userAgent=${_currentConfig.userAgent}, '
        'referer=${_currentConfig.referer}, '
        'protocolWhitelist=${_currentConfig.protocolWhitelist}');

    final headers = _currentConfig.buildHttpHeaders();
    // ignore: avoid_print
    print('[PlayerController] HTTP headers: $headers');

    // Build per-media MPV options from the config. These are passed as
    // extras to the Media constructor so mpv applies them for this specific
    // playback session (e.g. protocol-whitelist for HLS/TS streams).
    final mpvOptions = _currentConfig.buildMpvOptions();
    // ignore: avoid_print
    print('[PlayerController] MPV options: $mpvOptions');

    final media = Media(
      url,
      httpHeaders: headers.isNotEmpty ? headers : null,
      extras: mpvOptions.isNotEmpty ? mpvOptions : null,
    );

    try {
      await _player.open(media, play: autoPlay);
      // ignore: avoid_print
      print('[PlayerController] _player.open() succeeded');
    } catch (e, st) {
      // ignore: avoid_print
      print('[PlayerController] _player.open() FAILED: $e');
      // ignore: avoid_print
      print('[PlayerController] stack: $st');

      // Fallback: retry with software decoding (fixes AVI / legacy codec
      // playback where the hardware decoder cannot handle the stream but
      // audio still plays).
      // ignore: avoid_print
      print('[PlayerController] Retrying with software decoding fallback…');
      final fallbackMedia = Media(
        url,
        httpHeaders: headers.isNotEmpty ? headers : null,
        extras: {
          'hwdec': 'no',
          'vo': 'gpu',
          'vd': 'lavc',
        },
      );

      try {
        await _player.open(fallbackMedia, play: autoPlay);
        // ignore: avoid_print
        print('[PlayerController] Fallback open() succeeded');
      } catch (e2, st2) {
        // ignore: avoid_print
        print('[PlayerController] Fallback open() also FAILED: $e2');
        // ignore: avoid_print
        print('[PlayerController] fallback stack: $st2');
        _error = 'Failed to open stream: $e2';
        notifyListeners();
        return;
      }
    }

    // Re-apply audio/subtitle delay properties after the new playback chain
    // is up, because mpv resets them when the media changes. Both are zero
    // here (state is reset at the top of open()), but applying them explicitly
    // guarantees the new stream starts with a clean delay state.
    _applyAudioDelayProperty();
    _applySubDelayProperty();

    // Reset the real-progress flag again now that open() has settled: the
    // optimistic `playing = true` event (and a stale position value from the
    // previous media) can arrive during the await above and must not count
    // as playback progress for the new stream.
    _everPlayed = false;

    // Start the startup timeout -- if playback never begins, surface an
    // error. When [autoPlay] is false (the resume flow opens the player
    // paused so the player screen can seek first), the timer is NOT started
    // here: a paused player is not a timed-out player. The timeout is armed
    // lazily by the first [play] call (see [_armStartupTimeout]) so the
    // paused-for-resume window is never mistaken for a dead stream.
    _timeoutTimer?.cancel();
    _timeoutArmed = false;
    if (autoPlay) {
      _armStartupTimeout();
    }
  }

  /// Arms the 15-second startup timeout exactly once per [open] call. A no-op
  /// when the timeout is already running. Called immediately for
  /// `autoPlay: true` opens and lazily from [play] for paused opens.
  ///
  /// The timer is deliberately NOT cancelled by media_kit's optimistic
  /// `playing = true` event (see [_playingSub]): it only reports a timeout
  /// when no real playback progress has been seen ([_everPlayed] is still
  /// false), so a stream that merely starts slowly is never flagged, while a
  /// dead/unreachable stream surfaces an error instead of buffering forever.
  void _armStartupTimeout() {
    if (_timeoutArmed) return;
    _timeoutArmed = true;
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!_everPlayed && _error == null) {
        _error =
            'Stream timed out. The channel may be offline or unreachable.';
        // ignore: avoid_print
        print('[PlayerEngine] TIMEOUT — isPlaying=$_isPlaying, '
            'isBuffering=$_isBuffering, everPlayed=$_everPlayed, '
            'error=$_error');
        notifyListeners();
      }
    });
  }

  /// Records and publishes a fatal playback error.
  void _surfaceError(String msg) {
    _error = msg;
    _isBuffering = false;
    _timeoutTimer?.cancel();
    // ignore: avoid_print
    print('[PlayerEngine] ERROR surfaced: $msg');
    notifyListeners();
  }

  /// Re-open the last stream URL (e.g. after an error).
  Future<void> retry() async {
    if (_lastUrl != null) {
      await open(_lastUrl!, config: _lastConfig);
    }
  }

  /// Start or resume playback.
  void play() {
    // First play() after a paused open arms the startup timeout (see
    // [open]); for autoPlay opens the timeout is already armed and this is
    // a no-op.
    _armStartupTimeout();
    _player.play();
  }

  /// Pause playback.
  void pause() => _player.pause();

  /// Toggle between play and pause.
  void togglePlay() => _isPlaying ? pause() : play();

  /// Seek to [position].
  Future<void> seek(Duration position) => _player.seek(position);

  /// Seek by [offset] relative to the current position.
  Future<void> seekBy(Duration offset) =>
      _player.seek(_position + offset);

  /// Seek to a fraction [0, 1] of the total duration.
  Future<void> seekFractionally(double fraction) {
    if (_duration <= Duration.zero) return Future.value();
    final target = Duration(
      milliseconds: (_duration.inMilliseconds * fraction).round(),
    );
    return seek(target);
  }

  // -- Track controls --------------------------------------------------------

  /// Switch to the given [AudioTrack].
  Future<void> setAudioTrack(AudioTrack track) =>
      _player.setAudioTrack(track);

  /// Switch to the given [SubtitleTrack].
  /// Pass [SubtitleTrack.no()] to disable subtitles.
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _player.setSubtitleTrack(track);

  // ---------------------------------------------------------------------------
  // Public API — VLC-grade playback controls
  // ---------------------------------------------------------------------------

  // -- Playback rate ---------------------------------------------------------

  /// Current playback rate. Persists across [open] calls.
  double get rate => _rate;

  /// Set playback rate, clamped to [0.25, 4.0].
  Future<void> setRate(double r) async {
    final clamped = r.clamp(0.25, 4.0);
    try {
      await _player.setRate(clamped);
    } catch (e) {
      debugPrint('[PlayerEngine] setRate($clamped) failed: $e');
    }
    _rate = clamped;
    notifyListeners();
  }

  // -- Audio / subtitle delay (seconds; negative = earlier) ------------------

  /// Audio delay in seconds (negative = audio plays earlier). Reset on open.
  double get audioDelay => _audioDelay;

  /// Set the audio delay in seconds. Negative values make audio earlier.
  Future<void> setAudioDelay(double s) async {
    _audioDelay = s;
    _applyAudioDelayProperty();
    notifyListeners();
  }

  /// Subtitle delay in seconds (negative = subs play earlier). Reset on open.
  double get subDelay => _subDelay;

  /// Set the subtitle delay in seconds. Negative values make subs earlier.
  Future<void> setSubDelay(double s) async {
    _subDelay = s;
    _applySubDelayProperty();
    notifyListeners();
  }

  // -- Aspect ratio override -------------------------------------------------

  /// Supported aspect-ratio override presets.
  static const List<String> aspectPresets = ['16:9', '4:3', '1:1', '21:9', '2.35:1'];

  /// Current aspect-ratio override preset, or null when off. Reset on open.
  String? get aspectOverride => _aspectOverride;

  /// Override the display aspect ratio. Pass null to disable the override.
  Future<void> setAspectRatio(String? aspect) async {
    _setProperty('video-aspect-override', aspect ?? 'no');
    _aspectOverride = aspect;
    notifyListeners();
  }

  // -- Rotation ---------------------------------------------------------------

  /// Current video rotation in degrees (0/90/180/270). Reset on open.
  int get rotation => _rotation;

  /// Rotate the video by [degrees] (normalized to 0/90/180/270).
  Future<void> setRotation(int degrees) async {
    final normalized = ((degrees % 360) + 360) % 360;
    _setProperty('video-rotate', '$normalized');
    _rotation = normalized;
    notifyListeners();
  }

  // -- Deinterlace -------------------------------------------------------------

  /// Whether deinterlacing is enabled. Reset on open.
  bool get deinterlace => _deinterlace;

  /// Enable or disable deinterlacing.
  Future<void> setDeinterlace(bool on) async {
    _setProperty('deinterlace', on ? 'yes' : 'no');
    _deinterlace = on;
    notifyListeners();
  }

  // -- Network buffer ----------------------------------------------------------

  /// Current demuxer buffer size in megabytes. Persists across [open] calls.
  int get bufferMb => _bufferMb;

  /// Set the demuxer maximum buffer size in megabytes.
  Future<void> setBufferMegabytes(int mb) async {
    _setProperty('demuxer-max-bytes', '${mb * 1024 * 1024}');
    _bufferMb = mb;
    notifyListeners();
  }

  // -- Screenshot --------------------------------------------------------------

  /// Capture the current video frame as a PNG, or null on failure.
  Future<Uint8List?> takeScreenshot() async {
    try {
      return await _player.screenshot(format: 'image/png');
    } catch (e) {
      debugPrint('[PlayerEngine] takeScreenshot() failed: $e');
      return null;
    }
  }

  // -- Equalizer ---------------------------------------------------------------

  /// Whether the audio equalizer is available on this engine.
  ///
  /// The installed media_kit (1.2.6) does not ship an `Equalizer` API, so
  /// this is `false` and [setEqualizerPreset] is a safe no-op. UI layers
  /// should hide equalizer controls when this is false.
  bool get equalizerAvailable => _equalizerAvailable;

  /// Currently selected equalizer preset name, or null (Flat / disabled).
  String? get equalizerPreset => _equalizerPreset;

  /// Supported equalizer preset names.
  static const List<String> equalizerPresets = [
    'Flat',
    'Bass Boost',
    'Rock',
    'Pop',
    'Vocal Boost',
    'Treble Boost',
  ];

  /// Apply a named equalizer preset, or null to reset to Flat.
  ///
  /// No-op while [equalizerAvailable] is false.
  Future<void> setEqualizerPreset(String? name) async {
    if (!_equalizerAvailable) {
      debugPrint('[PlayerEngine] setEqualizerPreset("$name") ignored: '
          'equalizer unavailable');
      return;
    }
    _equalizerPreset = name;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _pendingErrorTimer?.cancel();
    _positionSub.cancel();
    _durationSub.cancel();
    _playingSub.cancel();
    _bufferingSub.cancel();
    _errorSub.cancel();
    _tracksSub.cancel();
    _trackSub.cancel();
    _volumeSub.cancel();
    _player.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Set a native mpv property, swallowing all failures so a rejected
  /// property can never break playback.
  void _setProperty(String key, String value) {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        native.setProperty(key, value).catchError((Object e) {
          debugPrint('[PlayerEngine] setProperty($key, $value) failed: $e');
        });
      }
    } catch (e) {
      debugPrint('[PlayerEngine] setProperty($key, $value) failed: $e');
    }
  }

  /// Push [_audioDelay] to the mpv `audio-delay` property (fire-and-forget).
  void _applyAudioDelayProperty() {
    _setProperty('audio-delay', _audioDelay.toStringAsFixed(2));
  }

  /// Push [_subDelay] to the mpv `sub-delay` property (fire-and-forget).
  void _applySubDelayProperty() {
    _setProperty('sub-delay', _subDelay.toStringAsFixed(2));
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }
}
