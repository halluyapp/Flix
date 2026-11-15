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
import '../models/caption_track.dart';
import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/offline_download.dart';
import '../models/provider_match.dart';
import '../models/stream_source.dart';
import '../models/tv_season.dart';
import '../services/diagnostics_service.dart';
import '../services/episode_navigator.dart';
import '../services/stream_resolver.dart';
import '../services/subtitle_service.dart';
import '../services/tmdb_service.dart';
import '../services/user_state_service.dart';
import '../widgets/flix_loading.dart';

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
  final String? offlineFilePath;
  final List<OfflineSubtitle> offlineSubtitles;

  const PlayerScreen({
    super.key,
    required this.item,
    this.providerMatch,
    this.startSeason = 1,
    this.startEpisode = 1,
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentSeason = widget.startSeason > 0 ? widget.startSeason : 1;
    _currentEpisode = widget.startEpisode > 0 ? widget.startEpisode : 1;
    _offlineSubtitles = widget.offlineSubtitles;
    unawaited(_enterPlayerMode());
    unawaited(_loadPreferences());
    if (_isOffline) {
      unawaited(_openOffline());
    } else {
      if (widget.item.mediaType == 'tv') {
        unawaited(_loadEpisodeIndex());
      }
      unawaited(_startPlayback());
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
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
      ]);
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

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoplayNext = prefs.getBool(_autoplayKey) ?? true;
      _preferredSubtitleLanguage = prefs.getString(_subtitleLanguageKey);
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
      // Try one alternate source before surfacing a fatal state.
      final alternative = _sources.firstWhere(
        (source) => source.url != first.url,
        orElse: () => first,
      );
      if (alternative.url != first.url) {
        _safeSetState(() => _selectedSource = alternative);
        started = await _initializeController(
          alternative,
          generation,
          startAt: startAt,
        );
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
          startAt: startAt ?? _position.value,
        );
        return;
      }
      _safeSetState(() {
        _phase = _PlayerPhase.failure;
        _failure = const ProviderException(
          ProviderErrorType.unknown,
          'Playback could not start with the built-in player.',
          diagnostic: 'exoplayer initialization failed',
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
      orElse: () => sources.first,
    );
    _safeSetState(() {
      _sources = sources;
      _selectedSource = selected;
      _captions = stream.captions;
      _selectedCaption = _pickCaption(stream.captions);
      _subtitleCues = const [];
      _subtitleText.value = '';
    });
    final caption = _selectedCaption;
    if (caption != null) {
      unawaited(_loadOnlineSubtitle(caption, generation));
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
        if (startAt != null && startAt > Duration.zero) {
          await controller.seekTo(startAt);
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
    final saved = _userState?.progressFor(
      widget.item,
      season: _currentSeason,
      episode: _currentEpisode,
    );
    if (saved != null && !saved.isCompleted && saved.positionSeconds > 5) {
      return Duration(seconds: saved.positionSeconds);
    }
    return Duration.zero;
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
      _saveProgress(value.position.inSeconds, value.duration.inSeconds);
    }

    _maybeOfferNextEpisode(value);
    _maybeMarkEnded(value);
  }

  void _maybeMarkEnded(VideoPlayerValue value) {
    if (_phase != _PlayerPhase.ready || !value.isCompleted) return;
    _saveProgress(value.duration.inSeconds, value.duration.inSeconds);
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
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
      _saveProgress(
        controller.value.position.inSeconds,
        controller.value.duration.inSeconds,
      );
    });
  }

  void _saveProgress(int positionSeconds, int durationSeconds) {
    if (_disposed) return;
    if (positionSeconds <= 0 || durationSeconds <= 0) return;
    _userState?.updateProgress(
      item: widget.item,
      season: widget.item.mediaType == 'tv' ? _currentSeason : 1,
      episode: widget.item.mediaType == 'tv' ? _currentEpisode : 1,
      episodeTitle: _episodeNameFor(_currentSeason, _currentEpisode),
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
    );
  }

  void _saveProgressNow() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _saveProgress(
      controller.value.position.inSeconds,
      controller.value.duration.inSeconds,
    );
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
      startAt: Duration.zero,
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

  Future<void> _loadOnlineSubtitle(CaptionTrack track, int generation) async {
    try {
      final cues = await SubtitleService.fetch(track);
      if (!_isCurrent(generation) || _selectedCaption?.id != track.id) return;
      _subtitleCues = cues;
      _subtitleText.value = SubtitleService.activeText(
        cues,
        _position.value,
      );
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

  Future<void> _loadOfflineSubtitle(OfflineSubtitle subtitle) async {
    try {
      if (!await File(subtitle.path).exists()) {
        _showMessage('This saved subtitle file is missing.');
        return;
      }
      final text = await File(subtitle.path).readAsString();
      final cues = SubtitleService.parse(text);
      if (!mounted || _disposed) return;
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
      _saveProgressNow();
      _dismissNextPrompt();
      setState(() {
        _currentSeason = next.season;
        _currentEpisode = next.episode;
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
    _saveProgressNow();
    _dismissNextPrompt();
    if (!_episodeIndex.containsKey(season)) await _ensureSeasonEpisodes(season);
    if (!mounted || _disposed) return;
    setState(() {
      _currentSeason = season;
      _currentEpisode = episode;
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
      _saveProgressNow();
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
    _saveProgress(clamped.inSeconds, _duration.value.inSeconds);
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
                        const ListTile(
                          title: Text(
                            'No subtitles are available from the provider.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
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
        state == AppLifecycleState.inactive) {
      _saveProgressNow();
      final controller = _controller;
      if (controller != null && controller.value.isPlaying) {
        controller.pause();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _saveProgressNow();
    _controlsTimer?.cancel();
    _progressTimer?.cancel();
    _nextPromptTimer?.cancel();
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
        if (didPop) _saveProgressNow();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideoSurface(),
            if (_phase == _PlayerPhase.failure) _buildFailure(),
            if (_phase == _PlayerPhase.ended) _buildEnded(),
            if (_phase != _PlayerPhase.failure &&
                _phase != _PlayerPhase.ended) ...[
              _buildBuffering(),
              _buildSubtitleOverlay(),
              if (_phase == _PlayerPhase.ready) _buildGestures(),
              if (_phase == _PlayerPhase.ready) _buildSeekRipples(),
              if (_phase != _PlayerPhase.ready) _buildLoading(),
              if (_phase == _PlayerPhase.ready && _showControls && !_locked)
                _buildHud(),
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
      return Center(
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio > 0
              ? controller.value.aspectRatio
              : 16 / 9,
          child: VideoPlayer(controller),
        ),
      );
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
          bottom: _showControls ? 112 : 34,
          child: IgnorePointer(
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 760),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.76),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    height: 1.28,
                    fontWeight: FontWeight.w600,
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
                  icon: Icons.subtitles_outlined,
                  tooltip: 'Audio and subtitles',
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
                if (widget.item.mediaType == 'tv' && !_isOffline)
                  _bottomAction(
                    icon: Icons.video_library_outlined,
                    label: 'Episodes',
                    onPressed: () => unawaited(_openEpisodesSheet()),
                  ),
                _bottomAction(
                  icon: Icons.subtitles_outlined,
                  label: 'Audio & Subtitles',
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
                          unawaited(_startPlayback(forceRefresh: true));
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
                          _startPlayback(forceRefresh: true),
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
