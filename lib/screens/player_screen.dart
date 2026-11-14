import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:provider/provider.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../core/constants/api_constants.dart';
import '../services/stream_resolver.dart';
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
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;

  bool _isResolving = true;
  String _statusMessage = 'Resolving streams via Zarhosting...';
  List<StreamSource> _availableSources = [];
  StreamSource? _selectedSource;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _resolveAndPlay();
  }

  Future<void> _resolveAndPlay() async {
    setState(() {
      _isResolving = true;
      _statusMessage = 'Searching stream catalog...';
    });

    final resolved = await _resolver.resolve(
      item: widget.item,
      season: widget.item.mediaType == 'tv' ? widget.startSeason : 0,
      episode: widget.item.mediaType == 'tv' ? widget.startEpisode : 0,
    );

    if (resolved == null || resolved.sources.isEmpty) {
      if (mounted) {
        setState(() {
          _isResolving = false;
          _statusMessage = 'No playable streams found for this title.';
        });
      }
      return;
    }

    _availableSources = resolved.sources;
    _selectedSource = resolved.bestSource;

    await _initializePlayer(_selectedSource!.url);
  }

  Future<void> _initializePlayer(String streamUrl) async {
    setState(() {
      _statusMessage = 'Buffering stream...';
    });

    _videoPlayerController?.dispose();
    _chewieController?.dispose();

    // Use required ExoPlayer CDN headers
    _videoPlayerController = VideoPlayerController.networkUrl(
      Uri.parse(streamUrl),
      httpHeaders: ApiConstants.zarhostingMediaHeaders,
    );

    await _videoPlayerController!.initialize();

    _chewieController = ChewieController(
      videoPlayerController: _videoPlayerController!,
      autoPlay: true,
      looping: false,
      allowFullScreen: true,
      showControls: true,
      materialProgressColors: ChewieProgressColors(
        playedColor: const Color(0xFFE50914),
        handleColor: const Color(0xFFE50914),
        backgroundColor: Colors.grey[800]!,
        bufferedColor: Colors.white24,
      ),
    );

    _videoPlayerController!.addListener(_onPlaybackTick);

    if (mounted) {
      setState(() {
        _isResolving = false;
      });
    }
  }

  void _onPlaybackTick() {
    if (_videoPlayerController == null || !_videoPlayerController!.value.isInitialized) return;
    final pos = _videoPlayerController!.value.position.inSeconds;
    final dur = _videoPlayerController!.value.duration.inSeconds;
    if (pos > 0 && pos % 10 == 0) {
      Provider.of<UserStateService>(context, listen: false).updateProgress(
        item: widget.item,
        season: widget.startSeason,
        episode: widget.startEpisode,
        positionSeconds: pos,
        durationSeconds: dur,
      );
    }
  }

  @override
  void dispose() {
    _videoPlayerController?.removeListener(_onPlaybackTick);
    _videoPlayerController?.dispose();
    _chewieController?.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_chewieController != null && _chewieController!.videoPlayerController.value.isInitialized)
            Center(child: Chewie(controller: _chewieController!))
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
          // Back button
          Positioned(
            top: 20,
            left: 20,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
