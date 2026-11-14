import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../models/caption_track.dart';
import '../models/episode.dart';
import '../models/offline_download.dart';
import '../core/constants/api_constants.dart';
import '../services/stream_resolver.dart';
import '../services/zarhosting_service.dart';
import '../services/tmdb_service.dart';
import '../services/subtitle_service.dart';
import '../widgets/player_media_options_sheet.dart';
import '../services/user_state_service.dart';

class PlayerScreen extends StatefulWidget {
  final MediaItem item;
  final ZarhostingTarget? providerTarget;
  final int startSeason;
  final int startEpisode;
  final String? offlineFilePath;
  final List<OfflineSubtitle> offlineSubtitles;

  const PlayerScreen({
    super.key,
    required this.item,
    this.providerTarget,
    this.startSeason = 1,
    this.startEpisode = 1,
    this.offlineFilePath,
    this.offlineSubtitles = const [],
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final StreamResolver _resolver = StreamResolver();
  final TmdbService _tmdb = TmdbService();

  VideoPlayerController? _videoPlayerController;
  Timer? _overlayHideTimer;
  Timer? _progressSaveTimer;
  UserStateService? _userState;

  bool _isResolving = true;
  String _statusMessage = 'Finding your title…';
  List<StreamSource> _availableSources = [];
  StreamSource? _selectedSource;
  List<CaptionTrack> _availableCaptions = [];
  CaptionTrack? _selectedCaption;
  List<SubtitleCue> _subtitleCues = const [];
  String _activeSubtitle = '';
  List<OfflineSubtitle> _offlineSubtitles = const [];
  OfflineSubtitle? _selectedOfflineSubtitle;
  bool _recoveringPlayback = false;
  int _playbackRecoveryAttempts = 0;

  int _currentSeason = 1;
  int _currentEpisode = 1;
  List<Episode> _seasonEpisodes = [];

  bool _showControls = true;
  bool _isPlaying = true;
  bool _isBuffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Binge next episode countdown state
  bool _showNextEpisodeCountdown = false;
  int _nextEpisodeCountdownSeconds = 10;
  Timer? _countdownTimer;

  // Seeking ripple indicators
  bool _showSeekLeftRipple = false;
  bool _showSeekRightRipple = false;

  @override
  void initState() {
    super.initState();
    _currentSeason = widget.startSeason;
    _currentEpisode = widget.startEpisode;

    _offlineSubtitles = widget.offlineSubtitles;
    unawaited(_enterPlayerMode());

    if (widget.item.mediaType == 'tv' && widget.offlineFilePath == null) {
      _loadEpisodesIfSeries();
    }
    if (widget.offlineFilePath != null) {
      _initializeOffline();
    } else {
      _resolveAndPlay();
    }
  }

  Future<void> _enterPlayerMode() async {
    try {
      await WakelockPlus.enable();
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (error) {
      debugPrint('Flix player mode could not be applied: $error');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolved once and cached: the provider must not be looked up from
    // dispose()/timers where the element tree is already deactivated.
    _userState = Provider.of<UserStateService>(context, listen: false);
  }

  Future<void> _loadEpisodesIfSeries() async {
    if (widget.item.mediaType == 'tv') {
      final eps = await _tmdb.getSeasonEpisodes(widget.item.id, _currentSeason);
      if (mounted) {
        setState(() {
          _seasonEpisodes = eps;
        });
      }
    }
  }

  ZarhostingTarget? get _effectiveProviderTarget {
    if (widget.providerTarget != null) return widget.providerTarget;
    final subjectId = widget.item.providerSubjectId;
    final detailPath = widget.item.providerDetailPath;
    if (subjectId == null || detailPath == null) return null;
    return ZarhostingTarget(
      subjectId: subjectId,
      detailPath: detailPath,
      title: widget.item.title,
      year: widget.item.releaseYear,
      isSeries: widget.item.mediaType == 'tv',
    );
  }

  Future<void> _resolveAndPlay({bool forceRefresh = false}) async {
    if (!mounted) return;
    setState(() {
      _isResolving = true;
      _statusMessage = 'Finding the best version…';
      _showNextEpisodeCountdown = false;
    });

    ResolvedMediaStream? resolved;
    try {
      resolved = await _resolver.resolve(
        item: widget.item,
        providerTarget: _effectiveProviderTarget,
        season: widget.item.mediaType == 'tv' ? _currentSeason : 0,
        episode: widget.item.mediaType == 'tv' ? _currentEpisode : 0,
        forceRefresh: forceRefresh,
      );
    } catch (error) {
      resolved = null;
      debugPrint('Flix stream resolution failed: $error');
      if (mounted && error is ProviderException) _statusMessage = error.message;
    }

    if (!mounted) return;

    if (resolved == null || resolved.selectableSources.isEmpty) {
      setState(() {
        _isResolving = false;
        _statusMessage =
            'This title is temporarily unavailable. Please try again.';
      });
      return;
    }

    _availableSources = resolved.selectableSources;
    final previousResolution = _selectedSource?.resolution;
    _selectedSource = resolved.selectableSources.firstWhere(
      (source) => source.resolution == previousResolution,
      orElse: () => resolved!.selectableSources.first,
    );
    _availableCaptions = resolved.captions;
    _selectedCaption = _availableCaptions.isEmpty
        ? null
        : _availableCaptions.firstWhere((c) => c.isDefault,
            orElse: () => _availableCaptions.first);
    unawaited(_selectOnlineCaption(_selectedCaption));

    final started = await _initializePlayer(_selectedSource!.url);
    if (!started && !forceRefresh && mounted) {
      _playbackRecoveryAttempts++;
      if (_playbackRecoveryAttempts <= 1) {
        await _resolveAndPlay(forceRefresh: true);
        return;
      }
    }
  }

  Future<bool> _initializePlayer(String streamUrl, {Duration? startAt}) async {
    setState(() {
      _isResolving = true;
      _statusMessage = 'Getting your title ready…';
    });

    final previousController = _videoPlayerController;
    _videoPlayerController = null;
    await previousController?.dispose();

    VideoPlayerController? controller;
    final profiles = widget.offlineFilePath == null
        ? ApiConstants.zarhostingMediaHeaderProfiles
        : const <Map<String, String>>[<String, String>{}];
    for (final profile in profiles) {
      try {
        final attemptController = widget.offlineFilePath != null
            ? VideoPlayerController.file(File(widget.offlineFilePath!))
            : VideoPlayerController.networkUrl(Uri.parse(streamUrl),
                httpHeaders: profile);
        controller = attemptController;
        _videoPlayerController = attemptController;
        await attemptController.initialize();
        if (attemptController.value.isInitialized) break;
        await attemptController.dispose();
        controller = null;
        _videoPlayerController = null;
      } catch (error) {
        debugPrint('Flix player initialization attempt failed: $error');
        await controller?.dispose();
        controller = null;
        _videoPlayerController = null;
      }
    }

    final activeController = controller;
    if (activeController == null || !activeController.value.isInitialized) {
      if (mounted) {
        setState(() {
          _isResolving = false;
          _isPlaying = false;
          _statusMessage =
              'Playback could not start. Check your connection and try again.';
        });
      }
      return false;
    }

    if (!mounted) {
      await activeController.dispose();
      return false;
    }

    activeController.addListener(_videoListener);

    // Resume where this profile left off (unless the episode was finished).
    final saved = _userState?.progressFor(
      widget.item,
      season: _currentSeason,
      episode: _currentEpisode,
    );
    final resumePosition = startAt ??
        (saved != null && !saved.isCompleted && saved.positionSeconds > 5
            ? Duration(seconds: saved.positionSeconds)
            : Duration.zero);
    if (resumePosition > const Duration(seconds: 1)) {
      await activeController.seekTo(resumePosition);
    }

    try {
      await activeController.play();
    } catch (error) {
      debugPrint('Flix could not start playback: $error');
      await activeController.dispose();
      if (mounted) setState(() => _videoPlayerController = null);
      return false;
    }

    _startProgressPeriodicSave();
    _resetOverlayTimer();

    if (mounted) {
      setState(() {
        _isResolving = false;
        _isPlaying = true;
        _duration = activeController.value.duration;
      });
    }
    return true;
  }

  Future<void> _initializeOffline() async {
    if (widget.offlineFilePath == null) return;
    final file = File(widget.offlineFilePath!);
    if (!await file.exists()) {
      if (mounted) {
        setState(() {
          _isResolving = false;
          _statusMessage =
              'This offline copy is missing. Remove it from Downloads and try again.';
        });
      }
      return;
    }
    setState(() {
      _isResolving = true;
      _statusMessage = 'Opening your offline copy…';
    });
    if (_offlineSubtitles.isNotEmpty) {
      unawaited(_selectOfflineSubtitle(_offlineSubtitles.first));
    }
    final started = await _initializePlayer('', startAt: Duration.zero);
    if (!started && mounted) {
      setState(() {
        _isResolving = false;
        _statusMessage = 'This offline copy could not be opened.';
      });
    }
  }

  Future<void> _recoverPlayback() async {
    if (widget.offlineFilePath != null) return;
    if (_recoveringPlayback) return;
    if (_playbackRecoveryAttempts >= 3) {
      final failedController = _videoPlayerController;
      _videoPlayerController = null;
      await failedController?.dispose();
      if (mounted) {
        setState(() {
          _isResolving = false;
          _isPlaying = false;
          _statusMessage = 'Playback was interrupted. Tap Retry to reconnect.';
        });
      }
      return;
    }
    _recoveringPlayback = true;
    _playbackRecoveryAttempts++;
    final resumeAt = _videoPlayerController?.value.position ?? _position;
    final resolution = _selectedSource?.resolution;
    if (mounted) {
      setState(() {
        _isResolving = true;
        _statusMessage = 'Reconnecting…';
      });
    }
    try {
      final fresh = await _resolver.resolve(
        item: widget.item,
        providerTarget: _effectiveProviderTarget,
        season: widget.item.mediaType == 'tv' ? _currentSeason : 0,
        episode: widget.item.mediaType == 'tv' ? _currentEpisode : 0,
        forceRefresh: true,
      );
      if (!mounted || fresh == null || fresh.selectableSources.isEmpty)
        throw StateError('No fresh stream was returned');
      _availableSources = fresh.selectableSources;
      _selectedSource = fresh.selectableSources.firstWhere(
        (source) => source.resolution == resolution,
        orElse: () => fresh.selectableSources.first,
      );
      _availableCaptions = fresh.captions;
      final started =
          await _initializePlayer(_selectedSource!.url, startAt: resumeAt);
      if (!started && mounted) throw StateError('Playback could not restart');
      _playbackRecoveryAttempts = 0;
    } catch (error) {
      debugPrint('Flix playback recovery failed: $error');
      if (mounted) {
        setState(() {
          _isResolving = false;
          _isPlaying = false;
          _statusMessage = 'Playback was interrupted. Tap Retry to reconnect.';
        });
      }
    } finally {
      _recoveringPlayback = false;
    }
  }

  Future<void> _selectOnlineCaption(CaptionTrack? track) async {
    setState(() {
      _selectedCaption = track;
      _subtitleCues = const [];
      _activeSubtitle = '';
    });
    if (track == null) return;
    try {
      final cues = await SubtitleService.fetch(track);
      if (!mounted || _selectedCaption?.id != track.id) return;
      setState(() => _subtitleCues = cues);
    } catch (error) {
      debugPrint('Flix subtitle load failed: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('This subtitle track could not be loaded.')),
        );
      }
    }
  }

  Future<void> _selectQuality(StreamSource source) async {
    _playbackRecoveryAttempts = 0;
    setState(() => _selectedSource = source);
    final started = await _initializePlayer(source.url, startAt: _position);
    if (!started && mounted) await _resolveAndPlay(forceRefresh: true);
  }

  Future<void> _selectOfflineSubtitle(OfflineSubtitle? subtitle) async {
    setState(() {
      _selectedOfflineSubtitle = subtitle;
      _subtitleCues = const [];
      _activeSubtitle = '';
    });
    if (subtitle == null) return;
    try {
      final text = await File(subtitle.path).readAsString();
      final cues = SubtitleService.parse(text);
      if (mounted) setState(() => _subtitleCues = cues);
    } catch (error) {
      debugPrint('Flix offline subtitle load failed: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('This saved subtitle file could not be opened.')),
        );
      }
    }
  }

  void _videoListener() {
    final controller = _videoPlayerController;
    if (controller == null || !controller.value.isInitialized) return;

    final val = controller.value;
    if (val.hasError) {
      unawaited(_recoverPlayback());
      return;
    }
    final pos = val.position;
    final dur = val.duration;
    final activeSubtitle = SubtitleService.activeText(_subtitleCues, pos);

    if (mounted) {
      setState(() {
        _position = pos;
        _duration = dur;
        _isPlaying = val.isPlaying;
        _isBuffering = val.isBuffering;
        _activeSubtitle = activeSubtitle;
      });
    }

    // Trigger Binge Countdown at 95% completion or last 45s on series episodes
    if (widget.item.mediaType == 'tv' &&
        widget.offlineFilePath == null &&
        dur.inSeconds > 60 &&
        !_showNextEpisodeCountdown) {
      final frac = dur.inSeconds > 0 ? pos.inSeconds / dur.inSeconds : 0.0;
      final remaining = dur.inSeconds - pos.inSeconds;
      if (frac >= 0.95 || remaining <= 45) {
        _startNextEpisodeCountdown();
      }
    }
  }

  void _startNextEpisodeCountdown() {
    if (_showNextEpisodeCountdown) return;
    setState(() {
      _showNextEpisodeCountdown = true;
      _nextEpisodeCountdownSeconds = 10;
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_nextEpisodeCountdownSeconds <= 1) {
        timer.cancel();
        _playNextEpisode();
      } else {
        setState(() {
          _nextEpisodeCountdownSeconds--;
        });
      }
    });
  }

  void _playNextEpisode() {
    _countdownTimer?.cancel();
    _saveProgressNow();

    final nextEp = _currentEpisode + 1;
    setState(() {
      _currentEpisode = nextEp;
      _showNextEpisodeCountdown = false;
    });

    _resolveAndPlay();
  }

  void _startProgressPeriodicSave() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _saveProgressNow();
    });
  }

  void _saveProgressNow() {
    final controller = _videoPlayerController;
    if (controller == null || !controller.value.isInitialized) return;
    final pos = controller.value.position.inSeconds;
    final dur = controller.value.duration.inSeconds;
    if (pos <= 0) return;
    _userState?.updateProgress(
      item: widget.item,
      season: _currentSeason,
      episode: _currentEpisode,
      positionSeconds: pos,
      durationSeconds: dur,
    );
  }

  void _resetOverlayTimer() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _togglePlayPause() {
    final controller = _videoPlayerController;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
      _resetOverlayTimer();
    }
    setState(() {});
  }

  void _seekBy(int seconds) {
    if (_videoPlayerController == null) return;
    final target = _position + Duration(seconds: seconds);
    final clamped = Duration(
      seconds: target.inSeconds.clamp(0, _duration.inSeconds),
    );
    _videoPlayerController!.seekTo(clamped);

    if (seconds > 0) {
      setState(() => _showSeekRightRipple = true);
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _showSeekRightRipple = false);
      });
    } else {
      setState(() => _showSeekLeftRipple = true);
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _showSeekLeftRipple = false);
      });
    }
    _resetOverlayTimer();
  }

  void _openAudioSubtitlesModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => PlayerMediaOptionsSheet(
        isOffline: widget.offlineFilePath != null,
        sources: _availableSources,
        selectedSource: _selectedSource,
        captions: _availableCaptions,
        selectedCaption: _selectedCaption,
        offlineSubtitles: _offlineSubtitles,
        selectedOfflineSubtitle: _selectedOfflineSubtitle,
        onSubtitleOff: () {
          if (widget.offlineFilePath != null) {
            _selectOfflineSubtitle(null);
          } else {
            _selectOnlineCaption(null);
          }
        },
        onQualitySelected: (source) => unawaited(_selectQuality(source)),
        onCaptionSelected: (caption) => _selectOnlineCaption(caption),
        onOfflineCaptionSelected: (subtitle) =>
            _selectOfflineSubtitle(subtitle),
      ),
    );
  }

  void _openEpisodesDrawer() {
    if (widget.offlineFilePath != null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.85,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Episodes • Season $_currentSeason',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: _seasonEpisodes.isEmpty
                    ? const Center(
                        child: Text(
                          'No episode data available.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _seasonEpisodes.length,
                        separatorBuilder: (_, __) =>
                            const Divider(color: Colors.white12),
                        itemBuilder: (context, idx) {
                          final ep = _seasonEpisodes[idx];
                          final isCurrent = ep.episodeNumber == _currentEpisode;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Stack(
                              alignment: Alignment.center,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.network(
                                    ep.thumbnail,
                                    width: 80,
                                    height: 50,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                        width: 80,
                                        height: 50,
                                        color: Colors.grey[900]),
                                  ),
                                ),
                                if (isCurrent)
                                  const Icon(Icons.play_circle_fill,
                                      color: Color(0xFFE50914), size: 24),
                              ],
                            ),
                            title: Text(
                              '${ep.episodeNumber}. ${ep.name}',
                              style: TextStyle(
                                color: isCurrent
                                    ? const Color(0xFFE50914)
                                    : Colors.white,
                                fontWeight: isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                            subtitle: Text(
                              '${ep.runtime}m',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12),
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              setState(() {
                                _currentEpisode = ep.episodeNumber;
                              });
                              _resolveAndPlay();
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  @override
  void dispose() {
    _saveProgressNow();
    _overlayHideTimer?.cancel();
    _progressSaveTimer?.cancel();
    _countdownTimer?.cancel();
    _videoPlayerController?.removeListener(_videoListener);
    _videoPlayerController?.dispose();

    unawaited(_leavePlayerMode());
    super.dispose();
  }

  Future<void> _leavePlayerMode() async {
    try {
      await WakelockPlus.disable();
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (error) {
      debugPrint('Flix player mode could not be restored: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Video Surface & Double-tap gesture detectors
          if (_videoPlayerController != null &&
              _videoPlayerController!.value.isInitialized)
            GestureDetector(
              onTap: () {
                setState(() {
                  _showControls = !_showControls;
                });
                if (_showControls) _resetOverlayTimer();
              },
              child: Center(
                child: AspectRatio(
                  aspectRatio: _videoPlayerController!.value.aspectRatio,
                  child: VideoPlayer(_videoPlayerController!),
                ),
              ),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isResolving)
                    const CircularProgressIndicator(color: Color(0xFFE50914))
                  else
                    const Icon(Icons.videocam_off_outlined,
                        color: Colors.white54, size: 48),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                  if (!_isResolving) ...[
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () {
                        _playbackRecoveryAttempts = 0;
                        _resolveAndPlay(forceRefresh: true);
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Retry'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE50914),
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back',
                          style: TextStyle(color: Colors.white70)),
                    ),
                  ],
                ],
              ),
            ),

          if (_activeSubtitle.isNotEmpty && !_isResolving)
            Positioned(
              left: 28,
              right: 28,
              bottom: _showControls ? 104 : 34,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 720),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(4)),
                    child: Text(
                      _activeSubtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          height: 1.25,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),

          // 2. Gesture Seek Detectors (Left 40% = seek -10s, Right 40% = seek +10s)
          Row(
            children: [
              Expanded(
                flex: 4,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: () => _seekBy(-10),
                  child: Container(),
                ),
              ),
              Expanded(flex: 2, child: Container()),
              Expanded(
                flex: 4,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: () => _seekBy(10),
                  child: Container(),
                ),
              ),
            ],
          ),

          // 3. Double-tap Seek Ripples
          if (_showSeekLeftRipple)
            Positioned(
              left: 60,
              top: MediaQuery.of(context).size.height / 2 - 30,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20)),
                child: const Row(
                  children: [
                    Icon(Icons.replay_10, color: Colors.white, size: 28),
                    SizedBox(width: 6),
                    Text('10s',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          if (_showSeekRightRipple)
            Positioned(
              right: 60,
              top: MediaQuery.of(context).size.height / 2 - 30,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20)),
                child: const Row(
                  children: [
                    Text('10s',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    SizedBox(width: 6),
                    Icon(Icons.forward_10, color: Colors.white, size: 28),
                  ],
                ),
              ),
            ),

          // 4. Buffering Spinner
          if (_isBuffering && !_isResolving)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFFE50914)),
            ),

          // 5. Cinema Player HUD Overlay
          if (_showControls && !_isResolving)
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black87,
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black87
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top Bar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white, size: 28),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.item.mediaType == 'tv'
                                ? '${widget.item.title}  •  S$_currentSeason:E$_currentEpisode'
                                : widget.item.title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.subtitles_outlined,
                              color: Colors.white, size: 26),
                          onPressed: _openAudioSubtitlesModal,
                        ),
                        if (widget.item.mediaType == 'tv' &&
                            widget.offlineFilePath == null)
                          IconButton(
                            icon: const Icon(Icons.video_library_outlined,
                                color: Colors.white, size: 26),
                            onPressed: _openEpisodesDrawer,
                          ),
                      ],
                    ),
                  ),

                  // Center Play/Pause/Seek Controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.replay_10,
                            color: Colors.white, size: 38),
                        onPressed: () => _seekBy(-10),
                      ),
                      const SizedBox(width: 40),
                      IconButton(
                        icon: Icon(
                            _isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                            color: Colors.white,
                            size: 64),
                        onPressed: _togglePlayPause,
                      ),
                      const SizedBox(width: 40),
                      IconButton(
                        icon: const Icon(Icons.forward_10,
                            color: Colors.white, size: 38),
                        onPressed: () => _seekBy(10),
                      ),
                    ],
                  ),

                  // Bottom Progress Bar & Time
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3.5,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6.0),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12.0),
                            activeTrackColor: const Color(0xFFE50914),
                            inactiveTrackColor: Colors.white24,
                            thumbColor: const Color(0xFFE50914),
                          ),
                          child: Slider(
                            value: _position.inSeconds
                                .toDouble()
                                .clamp(0.0, _duration.inSeconds.toDouble()),
                            max: _duration.inSeconds > 0
                                ? _duration.inSeconds.toDouble()
                                : 1.0,
                            onChanged: (val) {
                              _videoPlayerController
                                  ?.seekTo(Duration(seconds: val.toInt()));
                              _resetOverlayTimer();
                            },
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_position),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                            Text(
                              _formatDuration(_duration),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // 6. Next Episode Countdown Overlay (binge prompt)
          if (_showNextEpisodeCountdown)
            Positioned(
              bottom: 80,
              right: 28,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Next Episode in $_nextEpisodeCountdownSeconds...',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE50914),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                      ),
                      onPressed: _playNextEpisode,
                      child: const Text('Play Next',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white70, size: 18),
                      onPressed: () {
                        _countdownTimer?.cancel();
                        setState(() => _showNextEpisodeCountdown = false);
                      },
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
