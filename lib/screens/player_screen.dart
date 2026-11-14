import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../models/caption_track.dart';
import '../models/episode.dart';
import '../core/constants/api_constants.dart';
import '../services/stream_resolver.dart';
import '../services/tmdb_service.dart';
import '../services/user_state_service.dart';

class PlayerScreen extends StatefulWidget {
  final MediaItem item;
  final int startSeason;
  final int startEpisode;

  const PlayerScreen({
    super.key,
    required this.item,
    this.startSeason = 1,
    this.startEpisode = 1,
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

  bool _isResolving = true;
  String _statusMessage = 'Searching stream catalog...';
  List<StreamSource> _availableSources = [];
  StreamSource? _selectedSource;
  List<CaptionTrack> _availableCaptions = [];
  CaptionTrack? _selectedCaption;

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

    WakelockPlus.enable();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _loadEpisodesIfSeries();
    _resolveAndPlay();
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

  Future<void> _resolveAndPlay() async {
    setState(() {
      _isResolving = true;
      _statusMessage = 'Connecting to Zarhosting CDN stream...';
      _showNextEpisodeCountdown = false;
    });

    final resolved = await _resolver.resolve(
      item: widget.item,
      season: widget.item.mediaType == 'tv' ? _currentSeason : 0,
      episode: widget.item.mediaType == 'tv' ? _currentEpisode : 0,
    );

    if (resolved == null || resolved.selectableSources.isEmpty) {
      if (mounted) {
        setState(() {
          _isResolving = false;
          _statusMessage = 'No playable stream found for this title right now.';
        });
      }
      return;
    }

    _availableSources = resolved.selectableSources;
    _selectedSource = resolved.bestSource ?? _availableSources.first;
    _availableCaptions = resolved.captions;
    _selectedCaption = _availableCaptions.isNotEmpty ? _availableCaptions.firstWhere((c) => c.isDefault, orElse: () => _availableCaptions.first) : null;

    await _initializePlayer(_selectedSource!.url);
  }

  Future<void> _initializePlayer(String streamUrl) async {
    setState(() {
      _statusMessage = 'Buffering stream...';
    });

    _videoPlayerController?.dispose();

    // Use required ExoPlayer CDN headers profile
    _videoPlayerController = VideoPlayerController.networkUrl(
      Uri.parse(streamUrl),
      httpHeaders: ApiConstants.zarhostingMediaHeaders,
    );

    await _videoPlayerController!.initialize();

    _videoPlayerController!.addListener(_videoListener);
    await _videoPlayerController!.play();

    _startProgressPeriodicSave();
    _resetOverlayTimer();

    if (mounted) {
      setState(() {
        _isResolving = false;
        _isPlaying = true;
        _duration = _videoPlayerController!.value.duration;
      });
    }
  }

  void _videoListener() {
    if (_videoPlayerController == null || !_videoPlayerController!.value.isInitialized) return;

    final val = _videoPlayerController!.value;
    final pos = val.position;
    final dur = val.duration;

    if (mounted) {
      setState(() {
        _position = pos;
        _duration = dur;
        _isPlaying = val.isPlaying;
        _isBuffering = val.isBuffering;
      });
    }

    // Trigger Binge Countdown at 95% completion or last 45s on series episodes
    if (widget.item.mediaType == 'tv' && dur.inSeconds > 60 && !_showNextEpisodeCountdown) {
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
    if (_videoPlayerController == null || !_videoPlayerController!.value.isInitialized) return;
    final pos = _videoPlayerController!.value.position.inSeconds;
    final dur = _videoPlayerController!.value.duration.inSeconds;
    if (pos > 0) {
      Provider.of<UserStateService>(context, listen: false).updateProgress(
        item: widget.item,
        season: _currentSeason,
        episode: _currentEpisode,
        positionSeconds: pos,
        durationSeconds: dur,
      );
    }
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
    if (_videoPlayerController == null) return;
    if (_videoPlayerController!.value.isPlaying) {
      _videoPlayerController!.pause();
    } else {
      _videoPlayerController!.play();
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
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Audio / Quality
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'VIDEO QUALITY',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        ..._availableSources.map((s) {
                          final isSelected = s.url == _selectedSource?.url;
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${s.resolution} (${s.format})',
                              style: TextStyle(
                                color: isSelected ? const Color(0xFFE50914) : Colors.white,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            trailing: isSelected ? const Icon(Icons.check, color: Color(0xFFE50914)) : null,
                            onTap: () {
                              setModalState(() => _selectedSource = s);
                              Navigator.pop(ctx);
                              _initializePlayer(s.url);
                            },
                          );
                        }),
                      ],
                    ),
                  ),
                  const VerticalDivider(color: Colors.white24),
                  // Subtitles
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'SUBTITLES',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'Off',
                            style: TextStyle(
                              color: _selectedCaption == null ? const Color(0xFFE50914) : Colors.white,
                              fontWeight: _selectedCaption == null ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          trailing: _selectedCaption == null ? const Icon(Icons.check, color: Color(0xFFE50914)) : null,
                          onTap: () {
                            setModalState(() => _selectedCaption = null);
                            Navigator.pop(ctx);
                            setState(() => _selectedCaption = null);
                          },
                        ),
                        ..._availableCaptions.map((c) {
                          final isSelected = c.id == _selectedCaption?.id;
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              c.languageName,
                              style: TextStyle(
                                color: isSelected ? const Color(0xFFE50914) : Colors.white,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            trailing: isSelected ? const Icon(Icons.check, color: Color(0xFFE50914)) : null,
                            onTap: () {
                              setModalState(() => _selectedCaption = c);
                              Navigator.pop(ctx);
                              setState(() => _selectedCaption = c);
                            },
                          );
                        }),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openEpisodesDrawer() {
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
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
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
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFFE50914)))
                    : ListView.separated(
                        itemCount: _seasonEpisodes.length,
                        separatorBuilder: (_, __) => const Divider(color: Colors.white12),
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
                                    errorBuilder: (_, __, ___) => Container(width: 80, height: 50, color: Colors.grey[900]),
                                  ),
                                ),
                                if (isCurrent)
                                  const Icon(Icons.play_circle_fill, color: Color(0xFFE50914), size: 24),
                              ],
                            ),
                            title: Text(
                              '${ep.episodeNumber}. ${ep.name}',
                              style: TextStyle(
                                color: isCurrent ? const Color(0xFFE50914) : Colors.white,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                            subtitle: Text(
                              '${ep.runtime}m',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
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

    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Video Surface & Double-tap gesture detectors
          if (_videoPlayerController != null && _videoPlayerController!.value.isInitialized)
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
                  const CircularProgressIndicator(color: Color(0xFFE50914)),
                  const SizedBox(height: 16),
                  Text(
                    _statusMessage,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: const Row(
                  children: [
                    Icon(Icons.replay_10, color: Colors.white, size: 28),
                    SizedBox(width: 6),
                    Text('10s', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          if (_showSeekRightRipple)
            Positioned(
              right: 60,
              top: MediaQuery.of(context).size.height / 2 - 30,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: const Row(
                  children: [
                    Text('10s', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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

          // 5. Netflix Player HUD Overlay
          if (_showControls && !_isResolving)
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black87, Colors.transparent, Colors.transparent, Colors.black87],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top Bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.item.mediaType == 'tv'
                                ? '${widget.item.title}  •  S$_currentSeason:E$_currentEpisode'
                                : widget.item.title,
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.subtitles_outlined, color: Colors.white, size: 26),
                          onPressed: _openAudioSubtitlesModal,
                        ),
                        if (widget.item.mediaType == 'tv')
                          IconButton(
                            icon: const Icon(Icons.video_library_outlined, color: Colors.white, size: 26),
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
                        icon: const Icon(Icons.replay_10, color: Colors.white, size: 38),
                        onPressed: () => _seekBy(-10),
                      ),
                      const SizedBox(width: 40),
                      IconButton(
                        icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white, size: 64),
                        onPressed: _togglePlayPause,
                      ),
                      const SizedBox(width: 40),
                      IconButton(
                        icon: const Icon(Icons.forward_10, color: Colors.white, size: 38),
                        onPressed: () => _seekBy(10),
                      ),
                    ],
                  ),

                  // Bottom Progress Bar & Time
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3.5,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                            activeTrackColor: const Color(0xFFE50914),
                            inactiveTrackColor: Colors.white24,
                            thumbColor: const Color(0xFFE50914),
                          ),
                          child: Slider(
                            value: _position.inSeconds.toDouble().clamp(0.0, _duration.inSeconds.toDouble()),
                            max: _duration.inSeconds > 0 ? _duration.inSeconds.toDouble() : 1.0,
                            onChanged: (val) {
                              _videoPlayerController?.seekTo(Duration(seconds: val.toInt()));
                              _resetOverlayTimer();
                            },
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_position),
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            Text(
                              _formatDuration(_duration),
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // 6. Next Episode Countdown Overlay (Netflix Binge prompt)
          if (_showNextEpisodeCountdown)
            Positioned(
              bottom: 80,
              right: 28,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
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
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE50914),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      onPressed: _playNextEpisode,
                      child: const Text('Play Next', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
