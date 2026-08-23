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
      notifyListeners();
    });
    _durationSub = _player.stream.duration.listen((d) {
      _duration = d;
      notifyListeners();
    });
    _playingSub = _player.stream.playing.listen((p) {
      _isPlaying = p;
      if (p) {
        // Playback started -- cancel the startup timeout and clear any
        // stale error / buffering state that may have been set by a
        // non-fatal codec warning before the first frame decoded.
        _timeoutTimer?.cancel();
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
      // Only treat as a fatal error when the player is NOT playing.
      // Some codecs (e.g. AVI / DivX) emit non-fatal warnings during
      // hardware-decode fallback while playback continues fine in the
      // background.  In that case the error is a benign codec warning
      // and should not surface to the UI.
      if (!_player.state.playing) {
        _error = msg;
        _isBuffering = false;
        _timeoutTimer?.cancel();
        notifyListeners();
      }
      // If the player IS playing, silently ignore the warning.
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

  /// Last error message from the player, if any.
  String? _error;

  /// Stored for [retry].
  String? _lastUrl;
  PlayerConfig? _lastConfig;

  /// Fires if playback does not start within the timeout window.
  Timer? _timeoutTimer;

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

  /// Current volume in the range [0, 100].
  double get volume => _volume;

  /// Set volume. [value] is clamped to [0, 100].
  Future<void> setVolume(double value) async {
    await _player.setVolume(value.clamp(0, 100));
  }

  /// Volume as a fraction [0, 1] (convenient for slider widgets).
  double get volumeFraction => (_volume / 100).clamp(0.0, 1.0);

  /// Set volume from a fraction [0, 1].
  Future<void> setVolumeFraction(double fraction) =>
      setVolume(fraction * 100);

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
    _lastUrl = url;
    _lastConfig = config ?? PlayerConfig.defaultConfig;
    _currentConfig = _lastConfig!;

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

    // Start a timeout -- if playback never begins, surface an error.
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!_isPlaying && _error == null) {
        _error =
            'Stream timed out. The channel may be offline or unreachable.';
        // ignore: avoid_print
        print('[PlayerController] TIMEOUT — isPlaying=$_isPlaying, '
            'isBuffering=$_isBuffering, error=$_error');
        notifyListeners();
      }
    });
  }

  /// Re-open the last stream URL (e.g. after an error).
  Future<void> retry() async {
    if (_lastUrl != null) {
      await open(_lastUrl!, config: _lastConfig);
    }
  }

  /// Start or resume playback.
  void play() => _player.play();

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
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _timeoutTimer?.cancel();
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
