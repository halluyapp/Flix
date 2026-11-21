import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/constants/api_constants.dart';
import '../core/provider/provider_failures.dart';
import '../core/provider/provider_messages.dart';
import '../models/caption_load.dart';
import '../models/caption_track.dart';
import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/offline_download.dart';
import '../models/provider_match.dart';
import '../models/stream_source.dart';
import '../models/tv_season.dart';
import '../services/diagnostics_service.dart';
import '../services/episode_navigator.dart';
import '../services/player_gesture_logic.dart';
import '../services/source_preference.dart';
import '../services/stream_resolver.dart';
import '../services/subtitle_service.dart';
import '../services/tmdb_service.dart';
import '../services/user_state_service.dart';
import '../widgets/flix_loading.dart';

enum VideoAspectRatioMode {
  fit,
  fill,
  original,
}

String _aspectRatioLabel(VideoAspectRatioMode mode) {
  switch (mode) {
    case VideoAspectRatioMode.fit:
      return 'Fit';
    case VideoAspectRatioMode.fill:
      return 'Fill';
    case VideoAspectRatioMode.original:
      return '16:9';
  }
}

String _aspectRatioDescription(VideoAspectRatioMode mode) {
  switch (mode) {
    case VideoAspectRatioMode.fit:
      return 'Fit to Screen';
    case VideoAspectRatioMode.fill:
      return 'Zoom to Fill Screen';
    case VideoAspectRatioMode.original:
      return '16:9 Widescreen';
  }
}

enum _PlayerPhase {
  resolvingMatch,
  resolvingStream,
  initializing,
  ready,
  ended,
  failure,
}

/// Flix's player.
///
/// Playback is driven by a small, explicit state machine. Every asynchronous
/// step carries a generation token so a newer source selection (or a closed
/// player) can never be overwritten by an older initialisation.
class PlayerScreen extends StatefulWidget {
  final MediaItem item;
  final ProviderMatch? providerMatch;
  final int startSeason;
  final int startEpisode;
  final Duration? startAt;
  final String? offlineFilePath;
  final List<OfflineSubtitle> offlineSubtitles;

  const PlayerScreen({
    super.key,
    required this.item,
    this.providerMatch,
    this.startSeason = 1,
    this.startEpisode = 1,
    this.startAt,
    this.offlineFilePath,
    this.offlineSubtitles = const [],
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  static const Color _accent = Color(0xFFE50914);
  static const Duration _autoHideDelay = Duration(seconds: 4);
  static const String _autoplayKey = 'flix_player_autoplay_next';
  static const String _subtitleLanguageKey = 'flix_player_subtitle_language';
  static const String _subtitleSizeKey = 'flix_subtitle_size';
  static const String _subtitleOpacityKey = 'flix_subtitle_opacity';
  static const String _subtitlePositionKey = 'flix_subtitle_position';
  static const String _subtitleColorKey = 'flix_subtitle_color';
  static const String _subtitleBoldKey = 'flix_subtitle_bold';

  final StreamResolver _resolver = StreamResolver();
  final TmdbService _tmdb = TmdbService();
  UserStateService? _userState;

  // Notifiers keep high-frequency video ticks away from the whole widget tree.
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _duration = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _playing = ValueNotifier(false);
  final ValueNotifier<bool> _buffering = ValueNotifier(false);
  final ValueNotifier<String> _subtitleText = ValueNotifier('');

  VideoPlayerController? _controller;
  Timer? _controlsTimer;
  Timer? _progressTimer;
  Timer? _nextPromptTimer;
  Timer? _longPressTimer;
  Offset? _pointerDownPos;
  int _generation = 0;
  bool _disposed = false;
  int _profileIndex = 0;

  _PlayerPhase _phase = _PlayerPhase.resolvingMatch;
  ProviderException? _failure;
  String _statusMessage = 'Finding your title…';
  List<ProviderMatch> _candidates = const [];
  ProviderMatch? _chosenMatch;

  bool get _isOffline => widget.offlineFilePath != null;

  List<StreamSource> _sources = const [];
  StreamSource? _selectedSource;
  List<CaptionTrack> _captions = const [];
  CaptionLoad? _captionLoad;

  /// Set once the viewer picks a subtitle or "Off", so a late subtitle list
  /// never silently turns subtitles back on.
  bool _userChoseSubtitles = false;
  CaptionTrack? _selectedCaption;
  List<SubtitleCue> _subtitleCues = const [];
  List<OfflineSubtitle> _offlineSubtitles = const [];
  OfflineSubtitle? _selectedOfflineSubtitle;

  int _currentSeason = 1;
  int _currentEpisode = 1;
  List<TvSeason> _seasons = const [];
  final Map<int, List<Episode>> _episodeDetails = {};
  final Map<int, List<int>> _episodeIndex = {};
  bool _loadingEpisodes = false;

  bool _showControls = true;
  bool _locked = false;
  bool _recovering = false;
  int _recoveryAttempts = 0;
  double _speed = 1;
  bool _autoplayNext = true;
  String? _preferredSubtitleLanguage;
  int _lastSavedSecond = -1;
  double? _dragValue;
  bool _showLeftRipple = false;
  bool _showRightRipple = false;
  bool _showNextPrompt = false;
  int _nextCountdown = 8;
  bool _advancing = false;
  bool _isLandscape = true;
  VideoAspectRatioMode _aspectRatioMode = VideoAspectRatioMode.fit;
  bool _showAspectBadge = false;
  Timer? _aspectBadgeTimer;
  double _brightness = 1.0;
  bool _showBrightnessIndicator = false;
  Timer? _brightnessTimer;
  double _volume = 1.0;
  bool _showVolumeIndicator = false;
  Timer? _volumeTimer;
  bool _isPinching = false;
  double _subtitleSize = 17;
  double _subtitleOpacity = 0.76;
  double _subtitlePosition = 34;
  Color _subtitleColor = Colors.white;
  bool _subtitleBold = true;
  bool _isDragSeeking = false;
  bool _isVerticalAdjusting = false;
  double _gestureDx = 0;
  double _gestureDy = 0;
  Duration? _dragSeekTarget;
  bool _temporarySpeedActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentSeason = widget.startSeason > 0 ? widget.startSeason : 1;
    _currentEpisode = widget.startEpisode > 0 ? widget.startEpisode : 1;
    _offlineSubtitles = widget.offlineSubtitles;
    unawaited(_enterPlayerMode());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) {
        unawaited(_enterPlayerMode());
      }
    });
    unawaited(_loadPreferences());
    if (_isOffline) {
      unawaited(_openOffline());
    } else {
      if (widget.item.mediaType == 'tv') {
        unawaited(_loadEpisodeIndex());
      }
      // The explicitly supplied startAt (e.g. a Continue Watching tap) is
      // honored once, only for the first load. Every later start — episode
      // switches, autoplay, source recovery — resumes from the current
      // episode's saved progress.
      unawaited(_startPlayback(startAt: widget.startAt));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _userState = Provider.of<UserStateService>(context, listen: false);
  }

  bool _isCurrent(int generation) =>
      mounted && !_disposed && generation == _generation;

  void _safeSetState(VoidCallback fn) {
    if (!mounted || _disposed) return;
    setState(fn);
  }

  Future<void> _enterPlayerMode() async {
    try {
      await WakelockPlus.enable();
      if (_isLandscape) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeRight,
          DeviceOrientation.landscapeLeft,
        ]);
      } else {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (error) {
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'enter_player_mode',
        error: error,
      );
    }
  }

  Future<void> _leavePlayerMode() async {
    try {
      await WakelockPlus.disable();
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (error) {
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'leave_player_mode',
        error: error,
      );
    }
  }

  Future<void> _toggleOrientation() async {
    _isLandscape = !_isLandscape;
    try {
      if (_isLandscape) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeRight,
          DeviceOrientation.landscapeLeft,
        ]);
      } else {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]);
      }
    } catch (error) {
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'toggle_orientation',
        error: error,
      );
    }
    _armControlsTimer();
    _safeSetState(() {});
  }

  void _toggleAspectRatio() {
    _safeSetState(() {
      switch (_aspectRatioMode) {
        case VideoAspectRatioMode.fit:
          _aspectRatioMode = VideoAspectRatioMode.fill;
          break;
        case VideoAspectRatioMode.fill:
          _aspectRatioMode = VideoAspectRatioMode.original;
          break;
        case VideoAspectRatioMode.original:
          _aspectRatioMode = VideoAspectRatioMode.fit;
          break;
      }
      _showAspectBadge = true;
    });
    _aspectBadgeTimer?.cancel();
    _aspectBadgeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) _safeSetState(() => _showAspectBadge = false);
    });
    _armControlsTimer();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoplayNext = prefs.getBool(_autoplayKey) ?? true;
      _preferredSubtitleLanguage = prefs.getString(_subtitleLanguageKey);
      _subtitleSize = prefs.getDouble(_subtitleSizeKey) ?? 17;
      _subtitleOpacity = prefs.getDouble(_subtitleOpacityKey) ?? 0.76;
      _subtitlePosition = prefs.getDouble(_subtitlePositionKey) ?? 34;
      _subtitleColor = Color(prefs.getInt(_subtitleColorKey) ?? Colors.white.value);
      _subtitleBold = prefs.getBool(_subtitleBoldKey) ?? true;
      if (mounted) setState(() {});
    } catch (_) {
      // Defaults are safe when preferences are unavailable.
    }
  }

  Future<void> _persistAutoplay() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoplayKey, _autoplayNext);
    } catch (_) {}
  }

  Future<void> _persistSubtitleLanguage(String? language) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (language == null) {
        await prefs.remove(_subtitleLanguageKey);
      } else {
        await prefs.setString(_subtitleLanguageKey, language);
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------- playback

  Future<void> _startPlayback({
    bool forceRefresh = false,
    Duration? startAt,
  }) async {
    if (_isOffline) return;
    if (_temporarySpeedActive) unawaited(_endTemporarySpeed());
    final generation = ++_generation;
    _safeSetState(() {
      _phase = _chosenMatch == null &&
              widget.providerMatch == null &&
              ProviderMatch.fromMediaItem(widget.item) == null
          ? _PlayerPhase.resolvingMatch
          : _PlayerPhase.resolvingStream;
      _statusMessage = _phase == _PlayerPhase.resolvingMatch
          ? 'Finding your title…'
          : 'Finding the best stream…';
      _failure = null;
      _candidates = const [];
      _showNextPrompt = false;
    });
    _nextPromptTimer?.cancel();

    final resolution = await _resolver.resolve(
      item: widget.item,
      providerMatch: widget.providerMatch ?? _chosenMatch,
      season: _currentSeason,
      episode: _currentEpisode,
      forceRefresh: forceRefresh,
      onStage: (stage) {
        if (!_isCurrent(generation)) return;
        _safeSetState(() {
          _phase = stage == ResolutionStage.matchingProvider
              ? _PlayerPhase.resolvingMatch
              : _PlayerPhase.resolvingStream;
          _statusMessage = stage == ResolutionStage.matchingProvider
              ? 'Finding your title…'
              : 'Finding the best stream…';
        });
      },
    );

    if (!_isCurrent(generation)) return;

    if (!resolution.isSuccess) {
      _safeSetState(() {
        _phase = _PlayerPhase.failure;
        _failure = resolution.failure;
        _candidates = resolution.candidates;
      });
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'resolve',
        failureType: resolution.errorType,
        data: {
          'mediaType': widget.item.mediaType,
          'season': _currentSeason,
          'episode': _currentEpisode,
        },
      );
      return;
    }

    final stream = resolution.stream!;
    _applyResolution(stream, generation);
    if (!_isCurrent(generation)) return;

    final first = _selectedSource;
    if (first == null) {
      _safeSetState(() {
        _phase = _PlayerPhase.failure;
        _failure = const ProviderException(
          ProviderErrorType.noPlayableSources,
          'The provider returned no playable source for this title.',
        );
      });
      return;
    }

    var started = await _initializeController(
      first,
      generation,
      startAt: startAt,
    );
    if (!_isCurrent(generation)) return;

    if (!started) {
      // A decoder failure is about the file, not the headers: walk the other
      // qualities from the smallest up so a phone that cannot decode a 4K
      // stream still plays this title.
      for (final candidate in playbackCandidates(_sources)) {
        if (candidate.url == first.url) continue;
        if (!_isCurrent(generation)) return;
        _safeSetState(() => _selectedSource = candidate);
        started = await _initializeController(
          candidate,
          generation,
          startAt: startAt,
        );
        if (started) break;
      }
    }

    if (!_isCurrent(generation)) return;

    if (!started) {
      _resolver.invalidate(
        item: widget.item,
        season: _currentSeason,
        episode: _currentEpisode,
      );
      if (!forceRefresh) {
        await _startPlayback(
          forceRefresh: true,
          startAt: _currentPositionStart(),
        );
        return;
      }
      _safeSetState(() {
        _phase = _PlayerPhase.failure;
        _failure = const ProviderException(
          ProviderErrorType.unknown,
          'This stream could not be opened. The provider refused the file or '
          'this phone cannot decode it.',
          diagnostic: 'exoplayer initialization failed on every source',
        );
      });
    }
  }

  void _applyResolution(ResolvedMediaStream stream, int generation) {
    final previousQuality = _selectedSource?.qualityValue;
    final sources = stream.selectableSources;
    if (sources.isEmpty) return;
    final selected = sources.firstWhere(
      (source) => source.qualityValue == previousQuality,
      orElse: () => preferredSource(sources) ?? sources.first,
    );
    _safeSetState(() {
      _sources = sources;
      _selectedSource = selected;
      _captionLoad = stream.captionLoad;
      _captions = stream.captions;
      _selectedCaption = _pickCaption(stream.captions);
      _subtitleCues = const [];
      _subtitleText.value = '';
    });
    final caption = _selectedCaption;
    if (caption != null) {
      unawaited(_loadOnlineSubtitle(caption, generation));
    }
    if (stream.captionLoad.isPending) {
      // The list was still loading when the video started; fill it in later.
      unawaited(_awaitCaptions(generation));
    }
  }

  CaptionTrack? _pickCaption(List<CaptionTrack> captions) {
    if (captions.isEmpty) return null;
    final preferred = _preferredSubtitleLanguage;
    if (preferred != null) {
      for (final caption in captions) {
        if (caption.language == preferred) return caption;
      }
    }
    for (final caption in captions) {
      if (caption.isDefault) return caption;
    }
    return captions.first;
  }

  Future<bool> _initializeController(
    StreamSource source,
    int generation, {
    Duration? startAt,
  }) async {
    _safeSetState(() {
      _phase = _PlayerPhase.initializing;
      _statusMessage = 'Preparing playback…';
    });

    final previous = _controller;
    _controller = null;
    if (previous != null) {
      previous.removeListener(_onVideoTick);
      try {
        await previous.dispose();
      } catch (_) {}
    }
    _buffering.value = false;
    _playing.value = false;

    if (!_isCurrent(generation)) return false;

    if (_isOffline) {
      final path = widget.offlineFilePath;
      if (path == null) return false;
      final file = File(path);
      if (!await file.exists()) {
        _safeSetState(() {
          _phase = _PlayerPhase.failure;
          _failure = const ProviderException(
            ProviderErrorType.unknown,
            'This offline copy is missing. Remove it from Downloads and '
            'download it again.',
          );
        });
        return false;
      }
      try {
        final controller = VideoPlayerController.file(file);
        await controller.initialize();
        if (!_isCurrent(generation)) {
          await controller.dispose();
          return false;
        }
        _controller = controller;
        controller.addListener(_onVideoTick);
        _duration.value = controller.value.duration;
        final resumeAt = startAt ?? _resumePosition();
        if (resumeAt > Duration.zero) {
          await controller.seekTo(resumeAt);
          _showMessage('Resumed at ${_formatDuration(resumeAt)}');
        }
        await controller.play();
        _playing.value = true;
        _safeSetState(() {
          _phase = _PlayerPhase.ready;
          _showControls = true;
        });
        _startProgressTimer();
        _armControlsTimer();
        return true;
      } catch (error) {
        DiagnosticsService.instance.record(
          scope: 'player',
          operation: 'open_offline_file',
          error: error,
        );
        return false;
      }
    }

    final profiles = ApiConstants.zarhostingMediaHeaderProfiles
        .map((profile) => <String, String>{...profile, ...source.headers})
        .toList(growable: false);
    final startIndex = _profileIndex.clamp(0, profiles.length - 1).toInt();

    for (var attempt = 0; attempt < profiles.length; attempt++) {
      final index = (startIndex + attempt) % profiles.length;
      if (!_isCurrent(generation)) return false;
      VideoPlayerController? controller;
      try {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(source.url),
          httpHeaders: profiles[index],
        );
        await controller.initialize();
        if (!_isCurrent(generation)) {
          await controller.dispose();
          return false;
        }
        if (!controller.value.isInitialized) {
          throw StateError('Player did not initialise');
        }

        _controller = controller;
        _profileIndex = index;
        controller.addListener(_onVideoTick);
        await controller.setLooping(false);
        await controller.setPlaybackSpeed(_speed);

        final resumeAt = startAt ?? _resumePosition();
        if (resumeAt > Duration.zero) {
          await controller.seekTo(resumeAt);
          _showMessage('Resumed at ${_formatDuration(resumeAt)}');
        }
        await controller.play();

        _duration.value = controller.value.duration;
        _playing.value = true;
        _safeSetState(() {
          _phase = _PlayerPhase.ready;
          _showControls = true;
        });
        _startProgressTimer();
        _armControlsTimer();
        return true;
      } catch (error) {
        DiagnosticsService.instance.record(
          scope: 'player',
          operation: 'initialize_profile_$index',
          error: error,
          data: {'format': source.format, 'quality': source.resolution},
        );
        try {
          await controller?.dispose();
        } catch (_) {}
        _controller = null;
        final text = error.toString();
        if (text.contains('429') || text.contains('too many requests')) {
          await Future<void>.delayed(const Duration(milliseconds: 1400));
        }
        if (!_isCurrent(generation)) return false;
        if (!_shouldTryNextProfile(error, attempt, profiles.length)) break;
      }
    }
    return false;
  }

  /// Header profiles are only cycled when the failure plausibly involves a
  /// header/origin rejection. Permanent failures (missing file, bad URL) stop
  /// immediately instead of retrying every profile.
  bool _shouldTryNextProfile(Object error, int attempt, int total) {
    if (total <= 1) return false;
    final text = error.toString().toLowerCase();
    if (text.contains('404') ||
        text.contains('410') ||
        text.contains('not found')) {
      return false;
    }
    final headerRelated = const [
      '401',
      '403',
      '426',
      '428',
      '429',
      'forbidden',
      'unauthorized',
      'denied',
    ].any(text.contains);
    if (headerRelated) return true;
    // One alternate profile for an unclassified failure, never an endless loop.
    return attempt == 0;
  }

  Duration _resumePosition() {
    final userState = _userState ??
        (mounted ? Provider.of<UserStateService>(context, listen: false) : null);
    final saved = userState?.progressFor(
      widget.item,
      season: _currentSeason,
      episode: _currentEpisode,
    );
    if (saved != null && !saved.isCompleted && saved.positionSeconds > 5) {
      return Duration(seconds: saved.positionSeconds);
    }
    return Duration.zero;
  }

  /// The position playback was interrupted at, when a retry or recovery should
  /// resume exactly where it stopped. Null when nothing meaningful was played
  /// yet (callers then fall back to the saved position).
  Duration? _currentPositionStart() {
    final position = _position.value;
    if (position > Duration.zero) return position;
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      final controllerPosition = controller.value.position;
      if (controllerPosition > Duration.zero) return controllerPosition;
    }
    return null;
  }

  // ------------------------------------------------------------- video ticks

  void _onVideoTick() {
    final controller = _controller;
    if (controller == null || _disposed) return;
    final value = controller.value;
    if (!value.isInitialized) return;

    _position.value = value.position;
    if (value.duration > Duration.zero) _duration.value = value.duration;
    if (_playing.value != value.isPlaying) _playing.value = value.isPlaying;
    _buffering.value = value.isBuffering;

    final cue = SubtitleService.activeText(_subtitleCues, value.position);
    if (cue != _subtitleText.value) _subtitleText.value = cue;

    if (value.hasError) {
      unawaited(_recoverFromPlaybackError());
      return;
    }

    final seconds = value.position.inSeconds;
    if (seconds > 0 && (seconds - _lastSavedSecond).abs() >= 10) {
      _lastSavedSecond = seconds;
      unawaited(_saveProgress(value.position.inSeconds, value.duration.inSeconds));
    }

    _maybeOfferNextEpisode(value);
    _maybeMarkEnded(value);
  }

  void _maybeMarkEnded(VideoPlayerValue value) {
    if (_phase != _PlayerPhase.ready || !value.isCompleted) return;
    unawaited(_saveProgress(value.duration.inSeconds, value.duration.inSeconds));
    _safeSetState(() => _phase = _PlayerPhase.ended);
    _maybeOfferNextEpisode(value, force: true);
  }

  void _maybeOfferNextEpisode(VideoPlayerValue value, {bool force = false}) {
    if (widget.item.mediaType != 'tv' || _isOffline || _showNextPrompt) return;
    if (value.duration.inSeconds < 60) return;
    final remaining = value.duration.inSeconds - value.position.inSeconds;
    final fraction = value.position.inSeconds / value.duration.inSeconds;
    if (!force && remaining > 40 && fraction < 0.95) return;
    if (_nextEpisode == null) return;
    _openNextPrompt();
  }

  void _openNextPrompt() {
    if (_showNextPrompt || _isOffline) return;
    _nextPromptTimer?.cancel();
    _safeSetState(() {
      _showNextPrompt = true;
      _nextCountdown = 8;
    });
    if (!_autoplayNext) return;
    _nextPromptTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _disposed) {
        timer.cancel();
        return;
      }
      if (_nextCountdown <= 1) {
        timer.cancel();
        unawaited(_playNextEpisode());
      } else {
        _safeSetState(() => _nextCountdown--);
      }
    });
  }

  void _dismissNextPrompt() {
    _nextPromptTimer?.cancel();
    _safeSetState(() => _showNextPrompt = false);
  }

  // -------------------------------------------------------------- progress

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
      unawaited(_saveProgress(
        controller.value.position.inSeconds,
        controller.value.duration.inSeconds,
      ));
    });
  }

  Future<void> _saveProgress(int positionSeconds, int durationSeconds) async {
    if (positionSeconds <= 0 || durationSeconds <= 0) return;
    final userState = _userState ??
        (mounted ? Provider.of<UserStateService>(context, listen: false) : null);
    // Awaiting the service is what makes a save durable: the SharedPreferences
    // write completes before the app is suspended or killed.
    try {
      await userState?.updateProgress(
        item: widget.item,
        season: widget.item.mediaType == 'tv' ? _currentSeason : 1,
        episode: widget.item.mediaType == 'tv' ? _currentEpisode : 1,
        episodeTitle: _episodeNameFor(_currentSeason, _currentEpisode),
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
      );
    } catch (_) {
      // A failed save is best-effort; the next save retries with fresh data.
    }
  }

  Future<void> _saveProgressNow() async {
    final controller = _controller;
    final pos = (controller != null && controller.value.isInitialized)
        ? controller.value.position.inSeconds
        : _position.value.inSeconds;
    final dur = (controller != null && controller.value.isInitialized)
        ? controller.value.duration.inSeconds
        : _duration.value.inSeconds;
    await _saveProgress(pos, dur);
  }

  /// Saves and bounds the wait so an app exit or a background transition can
  /// never hang on a stalled storage channel.
  Future<void> _flushProgress() async {
    try {
      await _saveProgressNow().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Never let a slow storage write block the app from backgrounding.
    }
  }

  // --------------------------------------------------------------- recovery

  Future<void> _recoverFromPlaybackError() async {
    if (_isOffline || _recovering) return;
    if (_recoveryAttempts >= 2) {
      final failed = _controller;
      _controller = null;
      failed?.removeListener(_onVideoTick);
      await failed?.dispose();
      _safeSetState(() {
        _phase = _PlayerPhase.failure;
        _isPlayingReset();
        _failure = const ProviderException(
          ProviderErrorType.streamExpired,
          'The stream stopped and could not be restored automatically.',
        );
      });
      return;
    }
    _recovering = true;
    _recoveryAttempts++;
    final resumeAt = _controller?.value.position ?? _position.value;
    _resolver.invalidate(
      item: widget.item,
      season: _currentSeason,
      episode: _currentEpisode,
    );
    _safeSetState(() {
      _phase = _PlayerPhase.resolvingStream;
      _statusMessage = 'Refreshing the stream…';
    });
    try {
      await _startPlayback(forceRefresh: true, startAt: resumeAt);
    } finally {
      _recovering = false;
    }
  }

  void _isPlayingReset() {
    _playing.value = false;
    _buffering.value = false;
  }

  // ---------------------------------------------------------------- offline

  Future<void> _openOffline() async {
    final path = widget.offlineFilePath;
    if (path == null) return;
    final generation = ++_generation;
    _safeSetState(() {
      _phase = _PlayerPhase.initializing;
      _statusMessage = 'Opening your offline copy…';
    });
    final file = File(path);
    if (!await file.exists()) {
      _safeSetState(() {
        _phase = _PlayerPhase.failure;
        _failure = const ProviderException(
          ProviderErrorType.unknown,
          'This offline copy is no longer on this device. Remove it from '
          'Downloads and download it again.',
        );
      });
      return;
    }
    if (_offlineSubtitles.isNotEmpty) {
      await _loadOfflineSubtitle(_offlineSubtitles.first);
    }
    if (!_isCurrent(generation)) return;
    final started = await _initializeController(
      StreamSource(
        url: 'file://$path',
        resolution: 'Offline',
        qualityValue: 0,
        format: 'MP4',
        sizeBytes: await file.length(),
        durationSeconds: 0,
        isPreview: false,
      ),
      generation,
      startAt: widget.startAt,
    );
    if (!started && _isCurrent(generation)) {
      _safeSetState(() {
        _phase = _PlayerPhase.failure;
        _failure = const ProviderException(
          ProviderErrorType.unknown,
          'This offline file could not be opened by the player. Re-download it '
          'from Downloads.',
        );
      });
    }
  }

  // -------------------------------------------------------------- subtitles

  Future<void> _loadOnlineSubtitle(
    CaptionTrack track,
    int generation, {
    bool refreshed = false,
  }) async {
    try {
      final file = await SubtitleService.fetchValidated(track);
      if (!_isCurrent(generation) || _selectedCaption?.id != track.id) return;
      final cues = SubtitleService.parseText(file.text);
      _subtitleCues = cues;
      _subtitleText.value = SubtitleService.activeText(
        cues,
        _position.value,
      );
    } on SubtitleException catch (error) {
      if (!_isCurrent(generation) || _selectedCaption?.id != track.id) return;
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'load_online_subtitle',
        error: error,
        data: {'kind': error.failure.name, 'language': track.language},
      );
      if (error.needsFreshLink && !refreshed) {
        // A signed link can expire while the video plays: ask the provider
        // for a fresh subtitle list once and retry the same language.
        final load = await _resolver.refreshCaptions(
          item: widget.item,
          providerMatch: widget.providerMatch ?? _chosenMatch,
          season: _effectiveSeason,
          episode: _effectiveEpisode,
          forceRefresh: true,
        );
        if (!_isCurrent(generation) || _selectedCaption?.id != track.id) return;
        final replacement = load.isLoaded ? _findTrack(load.tracks, track) : null;
        if (replacement != null) {
          _applyCaptionLoad(load, generation);
          _safeSetState(() => _selectedCaption = replacement);
          await _loadOnlineSubtitle(replacement, generation, refreshed: true);
          return;
        }
      }
      if (_isCurrent(generation)) _showMessage(error.message);
    } catch (error) {
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'load_online_subtitle',
        error: error,
      );
      if (_isCurrent(generation)) {
        _showMessage('This subtitle track could not be loaded.');
      }
    }
  }

  /// Completes a subtitle lookup that outlived the resolve budget, so the list
  /// fills in without restarting playback.
  Future<void> _awaitCaptions(int generation) async {
    final load = await _resolver.refreshCaptions(
      item: widget.item,
      providerMatch: widget.providerMatch ?? _chosenMatch,
      season: _effectiveSeason,
      episode: _effectiveEpisode,
    );
    if (!_isCurrent(generation)) return;
    _applyCaptionLoad(load, generation);
  }

  /// Re-runs subtitle discovery without touching the video: playback position
  /// and the current stream stay exactly as they are.
  Future<void> _retryCaptions() async {
    final generation = _generation;
    _safeSetState(() => _captionLoad = CaptionLoad.pending());
    final load = await _resolver.refreshCaptions(
      item: widget.item,
      providerMatch: widget.providerMatch ?? _chosenMatch,
      season: _effectiveSeason,
      episode: _effectiveEpisode,
      forceRefresh: true,
    );
    if (!_isCurrent(generation)) return;
    _applyCaptionLoad(load, generation);
  }

  /// Stores a discovered list for the current episode. Auto-selects a
  /// language only when the viewer has not made a subtitle choice yet.
  void _applyCaptionLoad(CaptionLoad load, int generation) {
    if (!_isCurrent(generation)) return;
    final previous = _selectedCaption;
    final replacement = previous == null ? null : _findTrack(load.tracks, previous);
    final autoPick = previous == null && !_userChoseSubtitles && !_isOffline
        ? _pickCaption(load.tracks)
        : null;
    _safeSetState(() {
      _captionLoad = load;
      _captions = load.tracks;
      if (replacement != null) _selectedCaption = replacement;
      if (autoPick != null) _selectedCaption = autoPick;
    });
    if (autoPick != null) {
      unawaited(_loadOnlineSubtitle(autoPick, generation));
    }
  }

  /// Same subtitle after a list refresh: matched by id first, then by
  /// language and URL identity, since signed links change between requests.
  CaptionTrack? _findTrack(List<CaptionTrack> tracks, CaptionTrack track) {
    for (final candidate in tracks) {
      if (candidate.id == track.id && candidate.language == track.language) {
        return candidate;
      }
    }
    for (final candidate in tracks) {
      if (candidate.identityKey == track.identityKey) return candidate;
    }
    return null;
  }

  int get _effectiveSeason =>
      widget.item.mediaType == 'tv' ? _currentSeason : 0;

  int get _effectiveEpisode =>
      widget.item.mediaType == 'tv' ? _currentEpisode : 0;

  /// Status line for the subtitle sheet while the list is not usable.
  String? _captionStatusText() {
    final load = _captionLoad;
    if (load == null) return 'Loading subtitles…';
    if (load.isLoaded) return null;
    return load.userMessage;
  }

  bool _captionCanRetry() {
    final load = _captionLoad;
    return load != null && !load.isLoaded && !load.isPending;
  }

  Future<void> _loadOfflineSubtitle(OfflineSubtitle subtitle) async {
    try {
      if (!await File(subtitle.path).exists()) {
        _showMessage('This saved subtitle file is missing.');
        return;
      }
      final text = await File(subtitle.path).readAsString();
      final cues = SubtitleService.parseText(text);
      if (!mounted || _disposed) return;
      if (cues.isEmpty) {
        _showMessage('This saved subtitle has no readable captions.');
        return;
      }
      setState(() {
        _selectedOfflineSubtitle = subtitle;
        _selectedCaption = null;
        _subtitleCues = cues;
      });
      _subtitleText.value = SubtitleService.activeText(cues, _position.value);
    } catch (error) {
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'load_offline_subtitle',
        error: error,
      );
      _showMessage('This saved subtitle file could not be opened.');
    }
  }

  Future<void> _selectOnlineSubtitle(CaptionTrack? track) async {
    _userChoseSubtitles = true;
    setState(() {
      _selectedCaption = track;
      _subtitleCues = const [];
      _subtitleText.value = '';
    });
    if (track == null) {
      await _persistSubtitleLanguage(null);
      return;
    }
    _preferredSubtitleLanguage = track.language;
    await _persistSubtitleLanguage(track.language);
    await _loadOnlineSubtitle(track, _generation);
  }

  Future<void> _selectOfflineSubtitle(OfflineSubtitle? subtitle) async {
    _userChoseSubtitles = true;
    if (subtitle == null) {
      setState(() {
        _selectedOfflineSubtitle = null;
        _subtitleCues = const [];
      });
      _subtitleText.value = '';
      return;
    }
    await _loadOfflineSubtitle(subtitle);
  }

  // ---------------------------------------------------------------- sources

  Future<void> _selectSource(StreamSource source) async {
    if (source.url == _selectedSource?.url) return;
    final resumeAt = _controller?.value.position ?? _position.value;
    _recoveryAttempts = 0;
    final generation = _generation;
    setState(() => _selectedSource = source);
    final started = await _initializeController(
      source,
      generation,
      startAt: resumeAt,
    );
    if (!started && _isCurrent(generation)) {
      _safeSetState(() {
        _phase = _PlayerPhase.failure;
        _failure = const ProviderException(
          ProviderErrorType.unsupportedStreamFormat,
          'This version could not be played. Choose another source.',
        );
      });
    }
  }

  // --------------------------------------------------------------- episodes

  Future<void> _loadEpisodeIndex() async {
    if (widget.item.mediaType != 'tv' || _isOffline) return;
    try {
      final seasons = await _tmdb.getSeasons(widget.item.id);
      if (!mounted || _disposed) return;
      if (seasons.isNotEmpty) {
        setState(() => _seasons = seasons);
      }
    } catch (error) {
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'load_seasons',
        error: error,
      );
    }
    await _ensureSeasonEpisodes(_currentSeason);
  }

  Future<void> _ensureSeasonEpisodes(int season) async {
    if (_episodeIndex.containsKey(season)) return;
    try {
      final episodes = await _tmdb.getSeasonEpisodes(widget.item.id, season);
      if (!mounted || _disposed) return;
      setState(() {
        _episodeDetails[season] = episodes;
        _episodeIndex[season] = episodes
            .map((episode) => episode.episodeNumber)
            .toList(growable: false);
      });
    } catch (error) {
      DiagnosticsService.instance.record(
        scope: 'player',
        operation: 'load_episodes',
        error: error,
        data: {'season': season},
      );
    }
  }

  List<Episode> get _seasonEpisodes =>
      _episodeDetails[_currentSeason] ?? const <Episode>[];

  String _episodeNameFor(int season, int episode) {
    for (final entry in _episodeDetails[season] ?? const <Episode>[]) {
      if (entry.episodeNumber == episode) return entry.name;
    }
    return '';
  }

  EpisodePointer? get _nextEpisode => EpisodeNavigator.next(
        currentSeason: _currentSeason,
        currentEpisode: _currentEpisode,
        episodesBySeason: _episodeIndex,
        seasonOrder: _seasons
            .map((season) => season.seasonNumber)
            .toList(growable: false),
      );

  Future<void> _playNextEpisode() async {
    if (_advancing) return;
    final next = _nextEpisode;
    if (next == null) {
      _showMessage('This is the last available episode.');
      _dismissNextPrompt();
      return;
    }
    _advancing = true;
    try {
      if (!_episodeIndex.containsKey(next.season)) {
        _loadingEpisodes = true;
        await _ensureSeasonEpisodes(next.season);
        _loadingEpisodes = false;
      }
      if (!mounted || _disposed) return;
      await _saveProgressNow();
      _dismissNextPrompt();
      setState(() {
        _currentSeason = next.season;
        _currentEpisode = next.episode;
        _captionLoad = null;
        _captions = const [];
        _userChoseSubtitles = false;
        _selectedCaption = null;
        _selectedOfflineSubtitle = null;
        _subtitleCues = const [];
        _subtitleText.value = '';
        _recoveryAttempts = 0;
      });
      await _startPlayback();
    } finally {
      _advancing = false;
    }
  }

  Future<void> _playEpisode(int season, int episode) async {
    if (season == _currentSeason && episode == _currentEpisode) return;
    await _saveProgressNow();
    _dismissNextPrompt();
    if (!_episodeIndex.containsKey(season)) await _ensureSeasonEpisodes(season);
    if (!mounted || _disposed) return;
    setState(() {
      _currentSeason = season;
      _currentEpisode = episode;
      _captionLoad = null;
      _captions = const [];
      _userChoseSubtitles = false;
      _selectedCaption = null;
      _subtitleCues = const [];
      _subtitleText.value = '';
      _recoveryAttempts = 0;
    });
    await _startPlayback();
  }

  // --------------------------------------------------------------- controls

  void _toggleControls() {
    if (_locked) return;
    _safeSetState(() {
      _showControls = !_showControls;
      if (_showControls) {
        _armControlsTimer();
      } else {
        _controlsTimer?.cancel();
      }
    });
  }

  void _armControlsTimer() {
    _controlsTimer?.cancel();
    if (_locked) return;
    _controlsTimer = Timer(_autoHideDelay, () {
      if (!mounted || _disposed) return;
      if (_playing.value && !_locked) {
        _safeSetState(() => _showControls = false);
      }
    });
  }

  void _togglePlayPause() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
      unawaited(_saveProgressNow());
    } else {
      controller.play();
    }
    _armControlsTimer();
  }

  void _seekTo(Duration target) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final clampMax = _duration.value;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (clampMax > Duration.zero && target > clampMax ? clampMax : target);
    controller.seekTo(clamped);
    _position.value = clamped;
    unawaited(_saveProgress(clamped.inSeconds, _duration.value.inSeconds));
    _armControlsTimer();
  }

  void _seekBy(int seconds) {
    if (_controller == null) return;
    _seekTo(_position.value + Duration(seconds: seconds));
    if (seconds > 0) {
      _safeSetState(() => _showRightRipple = true);
      Future<void>.delayed(const Duration(milliseconds: 550), () {
        if (mounted && !_disposed) _safeSetState(() => _showRightRipple = false);
      });
    } else {
      _safeSetState(() => _showLeftRipple = true);
      Future<void>.delayed(const Duration(milliseconds: 550), () {
        if (mounted && !_disposed) _safeSetState(() => _showLeftRipple = false);
      });
    }
  }

  void _toggleLock() {
    _safeSetState(() {
      _locked = !_locked;
      _showControls = !_locked;
    });
    if (_locked) {
      _controlsTimer?.cancel();
    } else {
      _armControlsTimer();
    }
  }

  Future<void> _beginTemporarySpeed() async {
    final controller = _controller;
    if (_temporarySpeedActive ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    _temporarySpeedActive = true;
    _safeSetState(() {});
    try {
      await controller.setPlaybackSpeed(2.0);
    } catch (_) {
      _temporarySpeedActive = false;
      _safeSetState(() {});
    }
  }

  Future<void> _endTemporarySpeed() async {
    if (!_temporarySpeedActive) return;
    _temporarySpeedActive = false;
    try {
      await _controller?.setPlaybackSpeed(_speed);
    } catch (_) {
      // Source recovery will re-apply the user's persistent speed.
    }
    _safeSetState(() {});
  }

  Future<void> _setSpeed(double speed) async {
    _speed = speed;
    try {
      await _controller?.setPlaybackSpeed(speed);
    } catch (_) {}
    _safeSetState(() {});
  }

  void _showMessage(String message) {
    if (!mounted || _disposed) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF262626),
        ),
      );
  }

  // ----------------------------------------------------------------- sheets

  Future<void> _openSourcesSheet() async {
    if (_sources.isEmpty) {
      _showMessage(
        _isOffline
            ? 'This copy is playing from local storage.'
            : 'No alternate versions are available.',
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sheetHeader(sheetContext, 'Video quality'),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final source in _sources)
                        ListTile(
                          title: Text(
                            source.displayLabel,
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            [
                              source.sizeLabel,
                              if (source.codec.isNotEmpty) source.codec,
                              if (source.isAdaptive)
                                'Streaming only · cannot be saved offline',
                            ].join(' · '),
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          trailing: source.url == _selectedSource?.url
                              ? const Icon(Icons.check, color: _accent)
                              : null,
                          onTap: () {
                            Navigator.pop(sheetContext);
                            unawaited(_selectSource(source));
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openSubtitleSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        final offline = _isOffline;
        final subtitlesOff = offline
            ? _selectedOfflineSubtitle == null
            : _selectedCaption == null;
        final tracks = offline ? _offlineSubtitles : _captions;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sheetHeader(sheetContext, 'Subtitles'),
                ListTile(
                  leading: const Icon(Icons.tune, color: Colors.white70),
                  title: const Text('Subtitle appearance', style: TextStyle(color: Colors.white)),
                  onTap: () => _openSubtitleAppearance(sheetContext),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        title: const Text(
                          'Off',
                          style: TextStyle(color: Colors.white),
                        ),
                        trailing: subtitlesOff
                            ? const Icon(Icons.check, color: _accent)
                            : null,
                        onTap: () {
                          Navigator.pop(sheetContext);
                          if (offline) {
                            unawaited(_selectOfflineSubtitle(null));
                          } else {
                            unawaited(_selectOnlineSubtitle(null));
                          }
                        },
                      ),
                      if (tracks.isEmpty)
                        ListTile(
                          title: Text(
                            offline
                                ? 'No subtitles were saved with this download.'
                                : (_captionStatusText() ??
                                    'No subtitles are available.'),
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      if (!offline && _captionCanRetry())
                        ListTile(
                          leading: const Icon(
                            Icons.refresh,
                            color: Colors.white70,
                          ),
                          title: const Text(
                            'Retry subtitles',
                            style: TextStyle(color: Colors.white),
                          ),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            unawaited(_retryCaptions());
                          },
                        ),
                      if (offline)
                        for (final subtitle in _offlineSubtitles)
                          ListTile(
                            title: Text(
                              subtitle.languageName,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Saved on this device',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            trailing: _selectedOfflineSubtitle?.path ==
                                    subtitle.path
                                ? const Icon(Icons.check, color: _accent)
                                : null,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              unawaited(_selectOfflineSubtitle(subtitle));
                            },
                          )
                      else
                        for (final caption in _captions)
                          ListTile(
                            title: Text(
                              caption.languageName,
                              style: const TextStyle(color: Colors.white),
                            ),
                            trailing: _selectedCaption?.id == caption.id
                                ? const Icon(Icons.check, color: _accent)
                                : null,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              unawaited(_selectOnlineSubtitle(caption));
                            },
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openSubtitleAppearance(BuildContext sheetContext) async {
    await showDialog<void>(
      context: sheetContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          backgroundColor: const Color(0xFF202020),
          title: const Text('Subtitle appearance', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              Text('Size · ${_subtitleSize.round()} px', style: const TextStyle(color: Colors.white70)),
              Slider(value: _subtitleSize, min: 14, max: 26, divisions: 6, onChanged: (v) {
                updateDialog(() => _subtitleSize = v);
                unawaited(_saveSubtitleAppearance());
              }),
              Text('Background · ${(_subtitleOpacity * 100).round()}%', style: const TextStyle(color: Colors.white70)),
              Slider(value: _subtitleOpacity, min: 0, max: 0.9, divisions: 9, onChanged: (v) {
                updateDialog(() => _subtitleOpacity = v);
                unawaited(_saveSubtitleAppearance());
              }),
              Text('Bottom margin · ${_subtitlePosition.round()} px', style: const TextStyle(color: Colors.white70)),
              Slider(value: _subtitlePosition, min: 24, max: 140, divisions: 29, onChanged: (v) {
                updateDialog(() => _subtitlePosition = v);
                unawaited(_saveSubtitleAppearance());
              }),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bold text', style: TextStyle(color: Colors.white70)),
                value: _subtitleBold,
                onChanged: (value) { updateDialog(() => _subtitleBold = value); unawaited(_saveSubtitleAppearance()); },
              ),
              const Align(alignment: Alignment.centerLeft, child: Text('Text colour', style: TextStyle(color: Colors.white70))),
              Wrap(spacing: 12, children: [Colors.white, Colors.yellow, Colors.cyan, Colors.lightGreen].map((color) => IconButton(
                tooltip: 'Subtitle colour',
                onPressed: () { updateDialog(() => _subtitleColor = color); unawaited(_saveSubtitleAppearance()); },
                icon: Icon(Icons.circle, color: color, size: 20),
              )).toList()),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.black.withOpacity(_subtitleOpacity), borderRadius: BorderRadius.circular(4)),
                child: Text('Subtitle preview', style: TextStyle(color: _subtitleColor, fontSize: _subtitleSize, fontWeight: _subtitleBold ? FontWeight.w600 : FontWeight.normal, shadows: const [Shadow(color: Colors.black, blurRadius: 3)])),
              ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () {
              updateDialog(() { _subtitleSize = 17; _subtitleOpacity = 0.76; _subtitlePosition = 34; _subtitleColor = Colors.white; _subtitleBold = true; });
              unawaited(_saveSubtitleAppearance());
            }, child: const Text('Reset')),
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Done')),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _saveSubtitleAppearance() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_subtitleSizeKey, _subtitleSize);
      await prefs.setDouble(_subtitleOpacityKey, _subtitleOpacity);
      await prefs.setDouble(_subtitlePositionKey, _subtitlePosition);
      await prefs.setInt(_subtitleColorKey, _subtitleColor.value);
      await prefs.setBool(_subtitleBoldKey, _subtitleBold);
    } catch (_) {}
  }

  Future<void> _openSpeedSheet() async {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHeader(sheetContext, 'Playback speed'),
              for (final speed in speeds)
                ListTile(
                  title: Text(
                    speed == 1 ? 'Normal (1x)' : '${speed}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: _speed == speed
                      ? const Icon(Icons.check, color: _accent)
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_setSpeed(speed));
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openEpisodesSheet() async {
    if (_isOffline || widget.item.mediaType != 'tv') return;
    await _ensureSeasonEpisodes(_currentSeason);
    if (!mounted || _disposed) return;
    final seasonOptions = _seasons.isNotEmpty
        ? _seasons
            .where((season) => season.hasEpisodes)
            .toList(growable: false)
        : _episodeIndex.keys
            .map((number) => TvSeason(
                  seasonNumber: number,
                  name: 'Season $number',
                  episodeCount: _episodeIndex[number]?.length ?? 0,
                ))
            .toList(growable: false);
    if (seasonOptions.isEmpty) {
      _showMessage('No episode list is available for this show.');
      return;
    }
    var seasonValue = _currentSeason;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (modalContext, setModalState) {
            final episodes = _episodeDetails[seasonValue] ??
                (seasonValue == _currentSeason
                    ? _seasonEpisodes
                    : const <Episode>[]);
            return SafeArea(
              top: false,
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.78,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sheetHeader(modalContext, 'Episodes'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: DropdownButton<int>(
                        value: seasonValue,
                        dropdownColor: const Color(0xFF1F1F1F),
                        underline: const SizedBox.shrink(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        items: [
                          for (final season in seasonOptions)
                            DropdownMenuItem(
                              value: season.seasonNumber,
                              child: Text(season.label),
                            ),
                        ],
                        onChanged: (value) async {
                          if (value == null) return;
                          await _ensureSeasonEpisodes(value);
                          if (!mounted || _disposed) return;
                          setModalState(() => seasonValue = value);
                        },
                      ),
                    ),
                    const Divider(color: Colors.white12),
                    Expanded(
                      child: _loadingEpisodes && episodes.isEmpty
                          ? const Center(
                              child: FlixOrbitDots(size: 34),
                            )
                          : episodes.isEmpty
                              ? const Center(
                                  child: Text(
                                    'No episode data for this season.',
                                    style: TextStyle(color: Colors.white54),
                                  ),
                                )
                              : ListView.separated(
                                  itemCount: episodes.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(color: Colors.white12),
                                  itemBuilder: (context, index) {
                                    final episode = episodes[index];
                                    final isCurrent =
                                        episode.seasonNumber ==
                                                _currentSeason &&
                                            episode.episodeNumber ==
                                                _currentEpisode;
                                    return ListTile(
                                      leading: SizedBox(
                                        width: 78,
                                        height: 46,
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          child: Image.network(
                                            episode.thumbnail,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                Container(
                                              color: Colors.white10,
                                            ),
                                          ),
                                        ),
                                      ),
                                      title: Text(
                                        '${episode.episodeNumber}. ${episode.name}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: isCurrent
                                              ? _accent
                                              : Colors.white,
                                          fontSize: 14,
                                          fontWeight: isCurrent
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                      subtitle: Text(
                                        '${episode.runtime}m',
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                        ),
                                      ),
                                      trailing: isCurrent
                                          ? const Icon(
                                              Icons.play_circle_fill,
                                              color: _accent,
                                            )
                                          : null,
                                      onTap: () {
                                        Navigator.pop(modalContext);
                                        unawaited(
                                          _playEpisode(
                                            episode.seasonNumber,
                                            episode.episodeNumber,
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
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

  Future<void> _openMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHeader(sheetContext, 'Playback'),
              ListTile(
                leading: const Icon(Icons.speed, color: Colors.white70),
                title: const Text(
                  'Playback speed',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  '${_speed}x',
                  style: const TextStyle(color: Colors.white54),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_openSpeedSheet());
                },
              ),
              if (!_isOffline)
                ListTile(
                  leading: const Icon(Icons.high_quality, color: Colors.white70),
                  title: const Text(
                    'Video quality',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    _selectedSource?.displayLabel ?? 'Auto',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_openSourcesSheet());
                  },
                ),
              if (widget.item.mediaType == 'tv' && !_isOffline)
                ListTile(
                  leading: const Icon(Icons.video_library_outlined,
                      color: Colors.white70),
                  title: const Text(
                    'Episodes',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_openEpisodesSheet());
                  },
                ),
              SwitchListTile(
                secondary: const Icon(Icons.skip_next, color: Colors.white70),
                title: const Text(
                  'Autoplay next episode',
                  style: TextStyle(color: Colors.white),
                ),
                value: _autoplayNext,
                activeColor: _accent,
                onChanged: (value) {
                  setState(() => _autoplayNext = value);
                  unawaited(_persistAutoplay());
                  if (!value) _nextPromptTimer?.cancel();
                },
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline, color: Colors.white70),
                title: const Text(
                  'Lock controls',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleLock();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sheetHeader(BuildContext sheetContext, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () => Navigator.pop(sheetContext),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- lifecycle

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_endTemporarySpeed());
      // The flush completes before the process is backgrounded or killed, so
      // the current position survives the app closing or the phone switching.
      unawaited(_flushProgress());
      final controller = _controller;
      if (controller != null && controller.value.isPlaying) {
        controller.pause();
      }
    }
  }

  @override
  void dispose() {
    unawaited(_endTemporarySpeed());
    _longPressTimer?.cancel();
    unawaited(_flushProgress());
    _disposed = true;
    _generation++;
    _controlsTimer?.cancel();
    _progressTimer?.cancel();
    _nextPromptTimer?.cancel();
    _aspectBadgeTimer?.cancel();
    _brightnessTimer?.cancel();
    _volumeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_onVideoTick);
    controller?.dispose();
    _position.dispose();
    _duration.dispose();
    _playing.dispose();
    _buffering.dispose();
    _subtitleText.dispose();
    unawaited(_leavePlayerMode());
    super.dispose();
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_flushProgress());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideoSurface(),
            if (_brightness < 1.0)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: (1.0 - _brightness) * 0.75),
                  ),
                ),
              ),
            if (_phase == _PlayerPhase.failure) _buildFailure(),
            if (_phase == _PlayerPhase.ended) _buildEnded(),
            if (_phase != _PlayerPhase.failure &&
                _phase != _PlayerPhase.ended) ...[
              _buildBuffering(),
              _buildSubtitleOverlay(),
              if (_phase == _PlayerPhase.ready) _buildGestures(),
              if (_phase == _PlayerPhase.ready) _buildSeekRipples(),
              if (_showBrightnessIndicator) _buildBrightnessIndicator(),
              if (_showVolumeIndicator) _buildVolumeIndicator(),
              if (_showAspectBadge) _buildAspectRatioBadge(),
              if (_phase != _PlayerPhase.ready) _buildLoading(),
              if (_phase == _PlayerPhase.ready && _showControls && !_locked) ...[
                _buildHud(),
                if (MediaQuery.of(context).orientation == Orientation.portrait)
                  _buildPortraitRotatePrompt(),
              ],
              if (_phase == _PlayerPhase.ready && _locked)
                _buildLockedOverlay(),
              if (_showNextPrompt) _buildNextPrompt(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSurface() {
    final controller = _controller;
    if (controller != null &&
        controller.value.isInitialized &&
        _phase != _PlayerPhase.failure) {
      final videoAspect = controller.value.aspectRatio > 0
          ? controller.value.aspectRatio
          : 16 / 9;
      final videoSize = controller.value.size;
      final videoWidth = videoSize.width > 0 ? videoSize.width : 1920.0;
      final videoHeight = videoSize.height > 0 ? videoSize.height : 1080.0;

      Widget videoWidget = VideoPlayer(controller);

      switch (_aspectRatioMode) {
        case VideoAspectRatioMode.fit:
          return Center(
            child: AspectRatio(
              aspectRatio: videoAspect,
              child: videoWidget,
            ),
          );
        case VideoAspectRatioMode.fill:
          return SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: videoWidth,
                height: videoHeight,
                child: videoWidget,
              ),
            ),
          );
        case VideoAspectRatioMode.original:
          return Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: videoWidget,
            ),
          );
      }
    }
    return const ColoredBox(color: Colors.black);
  }

  Widget _buildLoading() {
    return FlixLoadingView(
      message: _statusMessage,
      detail: _phase == _PlayerPhase.initializing
          ? 'Rendering video with the built-in player'
          : null,
    );
  }

  Widget _buildBuffering() {
    return ValueListenableBuilder<bool>(
      valueListenable: _buffering,
      builder: (context, buffering, _) {
        if (!buffering || _phase != _PlayerPhase.ready) {
          return const SizedBox.shrink();
        }
        return const Center(child: FlixBufferingIndicator());
      },
    );
  }

  Widget _buildSubtitleOverlay() {
    return ValueListenableBuilder<String>(
      valueListenable: _subtitleText,
      builder: (context, text, _) {
        if (text.isEmpty || _phase != _PlayerPhase.ready) {
          return const SizedBox.shrink();
        }
        return Positioned(
          left: 24,
          right: 24,
          bottom: _showControls ? _subtitlePosition + 78 : _subtitlePosition,
          child: IgnorePointer(
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 760),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: _subtitleOpacity),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _subtitleColor,
                    fontSize: _subtitleSize,
                    height: 1.28,
                    fontWeight: _subtitleBold ? FontWeight.w600 : FontWeight.normal,
                    shadows: const [
                      Shadow(color: Colors.black, blurRadius: 3),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGestures() {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: (details) {
              final width = MediaQuery.of(context).size.width;
              if (details.localPosition.dx < width / 2) {
                _seekBy(-10);
              } else {
                _seekBy(10);
              }
            },
            onDoubleTap: () {},
            onLongPressStart: (_) => unawaited(_beginTemporarySpeed()),
            onLongPressEnd: (_) => unawaited(_endTemporarySpeed()),
            onLongPressCancel: () => unawaited(_endTemporarySpeed()),
            onScaleStart: (details) {
              _gestureDx = 0;
              _gestureDy = 0;
              _isDragSeeking = false;
              _isVerticalAdjusting = false;
              _dragSeekTarget = _position.value;
              if (details.pointerCount == 2) {
                _isPinching = true;
              }
            },
            onScaleUpdate: (details) {
              if (details.pointerCount == 1 && !_isPinching) {
                _gestureDx += details.focalPointDelta.dx;
                _gestureDy += details.focalPointDelta.dy;
                if (!_isDragSeeking && !_isVerticalAdjusting &&
                    (_gestureDx.abs() > 12 || _gestureDy.abs() > 12)) {
                  _isDragSeeking = _gestureDx.abs() > _gestureDy.abs();
                  _isVerticalAdjusting = !_isDragSeeking;
                }
                if (_isDragSeeking) {
                  final duration = _duration.value;
                  final width = MediaQuery.of(context).size.width;
                  if (duration > Duration.zero && width > 0) {
                    final proposed = PlayerGestureLogic.seekTarget(
                      start: _position.value,
                      horizontalDelta: _gestureDx,
                      screenWidth: width,
                      duration: duration,
                    );
                    _safeSetState(() => _dragSeekTarget = proposed);
                  }
                } else if (_isVerticalAdjusting) {
                  final size = MediaQuery.of(context).size;
                  final isLeft = details.focalPoint.dx < size.width / 2;
                  final delta = -details.focalPointDelta.dy / 250;
                  if (isLeft) {
                    _safeSetState(() {
                      _brightness = (_brightness + delta).clamp(0.15, 1.0);
                      _showBrightnessIndicator = true;
                    });
                    _brightnessTimer?.cancel();
                    _brightnessTimer = Timer(const Duration(milliseconds: 1500), () {
                      if (mounted) _safeSetState(() => _showBrightnessIndicator = false);
                    });
                  } else {
                    _safeSetState(() {
                      _volume = (_volume + delta).clamp(0.0, 1.0);
                      _showVolumeIndicator = true;
                    });
                    _controller?.setVolume(_volume);
                    _volumeTimer?.cancel();
                    _volumeTimer = Timer(const Duration(milliseconds: 1500), () {
                      if (mounted) _safeSetState(() => _showVolumeIndicator = false);
                    });
                  }
                }
              }
              if (details.pointerCount == 2 && _isPinching) {
                if (details.scale > 1.18 && _aspectRatioMode != VideoAspectRatioMode.fill) {
                  _safeSetState(() {
                    _aspectRatioMode = VideoAspectRatioMode.fill;
                    _showAspectBadge = true;
                  });
                  _aspectBadgeTimer?.cancel();
                  _aspectBadgeTimer = Timer(const Duration(milliseconds: 1500), () {
                    if (mounted) _safeSetState(() => _showAspectBadge = false);
                  });
                  _isPinching = false;
                } else if (details.scale < 0.82 && _aspectRatioMode != VideoAspectRatioMode.fit) {
                  _safeSetState(() {
                    _aspectRatioMode = VideoAspectRatioMode.fit;
                    _showAspectBadge = true;
                  });
                  _aspectBadgeTimer?.cancel();
                  _aspectBadgeTimer = Timer(const Duration(milliseconds: 1500), () {
                    if (mounted) _safeSetState(() => _showAspectBadge = false);
                  });
                  _isPinching = false;
                }
              }
            },
            onScaleEnd: (details) {
              if (_isDragSeeking && _dragSeekTarget != null) {
                _seekTo(_dragSeekTarget!);
              }
              _isPinching = false;
              _isDragSeeking = false;
              _isVerticalAdjusting = false;
              _safeSetState(() => _dragSeekTarget = null);
            },
          ),
        ),
        if (_temporarySpeedActive)
          Positioned(
            top: 28,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                  child: const Text('2× SPEED', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ),
        if (_isDragSeeking && _dragSeekTarget != null)
          Center(
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.78),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_gestureDx >= 0 ? Icons.fast_forward : Icons.fast_rewind,
                      color: Colors.white, size: 28),
                  const SizedBox(height: 6),
                  Text('${_formatDuration(_dragSeekTarget!)}  ${_gestureDx >= 0 ? '+' : '−'}${(_dragSeekTarget!.inSeconds - _position.value.inSeconds).abs()}s',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        if (_showControls && !_locked)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black87,
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, 0.28, 0.6, 1],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSeekRipples() {
    return Stack(
      children: [
        if (_showLeftRipple)
          Center(
            child: FractionalTranslation(
              translation: const Offset(-0.65, 0),
              child: _ripple(const Icon(Icons.replay_10, color: Colors.white), '-10s'),
            ),
          ),
        if (_showRightRipple)
          Center(
            child: FractionalTranslation(
              translation: const Offset(0.65, 0),
              child: _ripple(
                const Icon(Icons.forward_10, color: Colors.white),
                '+10s',
              ),
            ),
          ),
      ],
    );
  }

  Widget _ripple(Widget icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

    Widget _buildBrightnessIndicator() {
    return Positioned(
      left: 28,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _brightness > 0.6 ? Icons.brightness_7 : Icons.brightness_4,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(height: 10),
              Container(
                width: 6,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(3),
                ),
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: 6,
                  height: 80 * _brightness,
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${(_brightness * 100).round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVolumeIndicator() {
    return Positioned(
      right: 28,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _volume == 0
                    ? Icons.volume_off
                    : (_volume > 0.5 ? Icons.volume_up : Icons.volume_down),
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(height: 10),
              Container(
                width: 6,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(3),
                ),
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: 6,
                  height: 80 * _volume,
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${(_volume * 100).round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAspectRatioBadge() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.aspect_ratio, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(
              _aspectRatioDescription(_aspectRatioMode),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortraitRotatePrompt() {
    return Positioned(
      top: 68,
      left: 0,
      right: 0,
      child: Center(
        child: InkWell(
          onTap: () => unawaited(_toggleOrientation()),
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white24, width: 1),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.screen_rotation, color: Colors.white, size: 16),
                SizedBox(width: 8),
                Text(
                  'Rotate to Landscape for Fullscreen',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHud() {
    final title = widget.item.mediaType == 'tv'
        ? '${widget.item.title}  ·  S$_currentSeason:E$_currentEpisode'
        : widget.item.title;
    final episodeName = _episodeNameFor(_currentSeason, _currentEpisode);
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Row(
              children: [
                _hudIcon(
                  icon: Icons.close,
                  tooltip: 'Close player',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (episodeName.isNotEmpty)
                        Text(
                          episodeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                _hudIcon(
                  icon: Icons.aspect_ratio,
                  tooltip: 'Aspect ratio (${_aspectRatioLabel(_aspectRatioMode)})',
                  onPressed: _toggleAspectRatio,
                ),
                _hudIcon(
                  icon: Icons.screen_rotation,
                  tooltip: _isLandscape ? 'Switch to portrait' : 'Switch to landscape',
                  onPressed: () => unawaited(_toggleOrientation()),
                ),
                _hudIcon(
                  icon: Icons.subtitles_outlined,
                  tooltip: 'Subtitles',
                  onPressed: () => unawaited(_openSubtitleSheet()),
                ),
                _hudIcon(
                  icon: Icons.more_vert,
                  tooltip: 'More options',
                  onPressed: () => unawaited(_openMenu()),
                ),
              ],
            ),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _centerControl(
                icon: Icons.replay_10,
                tooltip: 'Rewind 10 seconds',
                size: 34,
                onPressed: () => _seekBy(-10),
              ),
              const SizedBox(width: 36),
              ValueListenableBuilder<bool>(
                valueListenable: _playing,
                builder: (context, playing, _) {
                  return IconButton(
                    tooltip: playing ? 'Pause' : 'Play',
                    iconSize: 62,
                    color: Colors.white,
                    icon: Icon(
                      playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                    ),
                    onPressed: () {
                      _togglePlayPause();
                      _armControlsTimer();
                    },
                  );
                },
              ),
              const SizedBox(width: 36),
              _centerControl(
                icon: Icons.forward_10,
                tooltip: 'Forward 10 seconds',
                size: 34,
                onPressed: () => _seekBy(10),
              ),
            ],
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: ValueListenableBuilder<Duration>(
              valueListenable: _duration,
              builder: (context, duration, _) {
                return ValueListenableBuilder<Duration>(
                  valueListenable: _position,
                  builder: (context, position, _) {
                    final total = duration.inMilliseconds.toDouble();
                    final current = _dragValue ??
                        position.inMilliseconds
                            .clamp(0, total <= 0 ? 0 : total.toInt())
                            .toDouble();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            activeTrackColor: _accent,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: _accent,
                            overlayColor: _accent.withValues(alpha: 0.2),
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                          ),
                          child: Slider(
                            value: total <= 0 ? 0 : current.clamp(0, total),
                            max: total <= 0 ? 1 : total,
                            onChanged: total <= 0
                                ? null
                                : (value) => setState(() => _dragValue = value),
                            onChangeEnd: total <= 0
                                ? null
                                : (value) {
                                    setState(() => _dragValue = null);
                                    _seekTo(
                                      Duration(milliseconds: value.round()),
                                    );
                                  },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(
                                  Duration(
                                    milliseconds: current.round(),
                                  ),
                                ),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                              Text(
                                _formatDuration(duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Row(
              children: [
                _bottomAction(
                  icon: Icons.speed,
                  label: 'Speed (${_formatSpeed(_speed)})',
                  onPressed: () => unawaited(_openSpeedSheet()),
                ),
                _bottomAction(
                  icon: _locked ? Icons.lock : Icons.lock_open,
                  label: 'Lock',
                  onPressed: _toggleLock,
                ),
                _bottomAction(
                  icon: Icons.aspect_ratio,
                  label: _aspectRatioLabel(_aspectRatioMode),
                  onPressed: _toggleAspectRatio,
                ),
                _bottomAction(
                  icon: Icons.screen_rotation,
                  label: _isLandscape ? 'Portrait' : 'Landscape',
                  onPressed: () => unawaited(_toggleOrientation()),
                ),
                if (widget.item.mediaType == 'tv' && !_isOffline)
                  _bottomAction(
                    icon: Icons.video_library_outlined,
                    label: 'Episodes',
                    onPressed: () => unawaited(_openEpisodesSheet()),
                  ),
                _bottomAction(
                  icon: Icons.subtitles_outlined,
                  label: 'Subtitles',
                  onPressed: () => unawaited(_openSubtitleSheet()),
                ),
                if (widget.item.mediaType == 'tv' &&
                    !_isOffline &&
                    _nextEpisode != null)
                  _bottomAction(
                    icon: Icons.skip_next,
                    label: 'Next Episode',
                    onPressed: () => unawaited(_playNextEpisode()),
                  ),
                if (!_isOffline)
                  _bottomAction(
                    icon: Icons.high_quality,
                    label: _selectedSource?.resolution ?? 'Quality',
                    onPressed: () => unawaited(_openSourcesSheet()),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hudIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: Colors.white, size: 24),
      onPressed: () {
        onPressed();
        _armControlsTimer();
      },
    );
  }

  Widget _centerControl({
    required IconData icon,
    required String tooltip,
    required double size,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      iconSize: size,
      color: Colors.white,
      icon: Icon(icon),
      onPressed: () {
        onPressed();
        _armControlsTimer();
      },
    );
  }

  Widget _bottomAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return TextButton.icon(
      onPressed: () {
        onPressed();
        _armControlsTimer();
      },
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 44),
      ),
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildLockedOverlay() {
    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: 'Unlock controls',
              icon: const Icon(Icons.lock, color: Colors.white),
              onPressed: _toggleLock,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNextPrompt() {
    return Positioned(
      right: 20,
      bottom: 84,
      child: Material(
        color: Colors.black.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Up next',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _autoplayNext
                        ? 'Next episode in ${_nextCountdown}s'
                        : 'Next episode ready',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => unawaited(_playNextEpisode()),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Play Next'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                onPressed: _dismissNextPrompt,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEnded() {
    final hasNext = _nextEpisode != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black87),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Finished',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        _seekTo(Duration.zero);
                        _safeSetState(() => _phase = _PlayerPhase.ready);
                        _togglePlayPause();
                      },
                      icon: const Icon(Icons.replay, size: 18),
                      label: const Text('Watch again'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                      ),
                    ),
                    if (hasNext)
                      ElevatedButton.icon(
                        onPressed: () => unawaited(_playNextEpisode()),
                        icon: const Icon(Icons.skip_next, size: 18),
                        label: const Text('Next episode'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                      ),
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text(
                        'Back to details',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFailure() {
    final failure = _failure ??
        const ProviderException(
          ProviderErrorType.unknown,
          'Playback could not start.',
        );
    final canChooseVersion = _candidates.isNotEmpty;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const FlixWordmark(fontSize: 30),
                const SizedBox(height: 18),
                Text(
                  ProviderMessages.titleFor(failure.type),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  ProviderMessages.bodyFor(failure.type),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                if (canChooseVersion) ...[
                  const SizedBox(height: 18),
                  const Text(
                    'Available versions',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final candidate in _candidates)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: OutlinedButton(
                        onPressed: () {
                          _chosenMatch = candidate;
                          unawaited(_startPlayback(
                            forceRefresh: true,
                            startAt: _currentPositionStart(),
                          ));
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                          minimumSize: const Size(double.infinity, 44),
                        ),
                        child: Text(
                          candidate.displayLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    if (!_isOffline)
                      ElevatedButton.icon(
                        onPressed: () => unawaited(
                          _startPlayback(
                            forceRefresh: true,
                            startAt: _currentPositionStart(),
                          ),
                        ),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text(
                          ProviderMessages.actionLabel(failure.type),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    if (widget.item.mediaType == 'tv' &&
                        !_isOffline &&
                        _nextEpisode != null)
                      OutlinedButton.icon(
                        onPressed: () => unawaited(_playNextEpisode()),
                        icon: const Icon(Icons.skip_next, size: 18),
                        label: const Text('Next episode'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                        ),
                      ),
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text(
                        'Back to details',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final total = duration.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  static String _formatSpeed(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
}
