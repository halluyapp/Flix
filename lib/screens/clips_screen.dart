import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/provider_clip.dart';
import '../models/media_item.dart';
import '../services/clips_service.dart';
import '../services/user_state_service.dart';
import '../services/zarhosting_service.dart';
import 'player_screen.dart';

class ClipsScreen extends StatefulWidget {
  const ClipsScreen({super.key});

  @override
  State<ClipsScreen> createState() => _ClipsScreenState();
}

class _ClipsScreenState extends State<ClipsScreen> {
  final ClipsService _clipsService = ClipsService();
  List<ProviderClip> _clips = const [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _loadError;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _loadClips();
  }

  Future<void> _loadClips({bool refresh = false}) async {
    if (refresh) {
      setState(() => _isRefreshing = true);
    } else if (_clips.isEmpty) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final clips = await _clipsService.fetchShortFilms();
      if (!mounted) return;
      setState(() {
        _clips = clips;
        _isLoading = false;
        _isRefreshing = false;
        _loadError = null;
        if (_currentPage >= clips.length) _currentPage = 0;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        _loadError = 'The short-film catalogue could not be reached.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFFE50914)),
              )
            : _clips.isEmpty
                ? _buildEmptyState()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      PageView.builder(
                        scrollDirection: Axis.vertical,
                        itemCount: _clips.length,
                        onPageChanged: (index) => setState(() => _currentPage = index),
                        itemBuilder: (context, index) => _buildClipPage(_clips[index]),
                      ),
                      Positioned(
                        left: 18,
                        top: 12,
                        child: Row(
                          children: [
                            const Text(
                              'FLIX',
                              style: TextStyle(
                                color: Color(0xFFE50914),
                                fontWeight: FontWeight.w900,
                                fontSize: 22,
                                letterSpacing: 2,
                              ),
                            ),
                            Container(
                              height: 18,
                              margin: const EdgeInsets.symmetric(horizontal: 10),
                              width: 1,
                              color: Colors.white54,
                            ),
                            const Text(
                              'CLIPS',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 8,
                        child: IconButton(
                          tooltip: 'Refresh short films',
                          onPressed: _isRefreshing ? null : () => _loadClips(refresh: true),
                          icon: _isRefreshing
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.refresh, color: Colors.white, size: 24),
                        ),
                      ),
                      Positioned(
                        right: 10,
                        bottom: 125,
                        child: _buildActions(_clips[_currentPage]),
                      ),
                      Positioned(
                        left: 18,
                        right: 92,
                        bottom: 22,
                        child: _buildCaption(_clips[_currentPage]),
                      ),
                      if (_clips.length > 1)
                        Positioned(
                          top: 54,
                          right: 22,
                          child: Text(
                            '${_currentPage + 1} / ${_clips.length}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }

  Widget _buildClipPage(ProviderClip clip) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (clip.posterUrl.isNotEmpty)
          CachedNetworkImage(
            imageUrl: clip.posterUrl,
            fit: BoxFit.cover,
            placeholder: (_, __) => _buildPosterFallback(),
            errorWidget: (_, __, ___) => _buildPosterFallback(),
          )
        else
          _buildPosterFallback(),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xB3000000),
                Color(0x08000000),
                Color(0x1A000000),
                Color(0xE6000000),
              ],
              stops: [0, 0.28, 0.58, 1],
            ),
          ),
        ),
        Align(
          alignment: Alignment.center,
          child: Material(
            color: Colors.black.withValues(alpha: 0.48),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: 'Play ${clip.title}',
              iconSize: 54,
              onPressed: () => _play(clip),
              icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPosterFallback() {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B1519), Color(0xFF171717), Color(0xFF080808)],
        ),
      ),
      child: Center(
        child: Icon(Icons.movie_outlined, color: Colors.white24, size: 84),
      ),
    );
  }

  Widget _buildCaption(ProviderClip clip) {
    final item = clip.toMediaItem();
    final inMyList = context.select<UserStateService, bool>(
      (userState) => userState.isInMyList(item),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFE50914),
            borderRadius: BorderRadius.circular(3),
          ),
          child: const Text(
            'SHORT FILM',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 10,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          clip.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 23,
            height: 1.08,
            fontWeight: FontWeight.w800,
            shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
          ),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (clip.year > 0)
              Text(
                '${clip.year}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            if (clip.rating > 0)
              Text(
                '★ ${clip.rating.toStringAsFixed(1)}',
                style: const TextStyle(
                  color: Color(0xFFF5C518),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            if (clip.country.isNotEmpty)
              Text(
                clip.country,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
          ],
        ),
        if (clip.genre.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            clip.genre,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
        ],
        if (clip.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            clip.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          height: 42,
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => _play(clip),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 24),
            label: const Text(
              'Play short film',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          inMyList ? 'Saved to your local My List' : 'Provider catalogue • Resource listed',
          style: const TextStyle(color: Colors.white60, fontSize: 10),
        ),
      ],
    );
  }

  Widget _buildActions(ProviderClip clip) {
    final item = clip.toMediaItem();
    final userState = context.read<UserStateService>();
    final inMyList = userState.isInMyList(item);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionButton(
          icon: inMyList ? Icons.check : Icons.add,
          label: inMyList ? 'In My List' : 'My List',
          onTap: () {
            userState.toggleMyList(item);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(inMyList ? 'Removed from My List' : 'Added to My List'),
                duration: const Duration(seconds: 2),
                backgroundColor: const Color(0xFF222222),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        _ActionButton(
          icon: Icons.info_outline,
          label: 'Details',
          onTap: () => _showDetails(clip),
        ),
      ],
    );
  }

  Future<void> _showDetails(ProviderClip clip) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white30,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Text(
                clip.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                [
                  if (clip.year > 0) '${clip.year}',
                  if (clip.country.isNotEmpty) clip.country,
                  'Short film',
                ].join(' • '),
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              if (clip.genre.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(clip.genre, style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
              if (clip.description.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  clip.description,
                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    _play(clip);
                  },
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play short film'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _play(ProviderClip clip) {
    final target = ZarhostingTarget(
      subjectId: clip.subjectId,
      detailPath: clip.detailPath,
      title: clip.title,
      year: clip.year,
      isSeries: false,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: clip.toMediaItem(),
          providerTarget: target,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.movie_filter_outlined, color: Color(0xFFE50914), size: 54),
            const SizedBox(height: 18),
            const Text(
              'Short films, verified by the catalogue',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              _loadError ??
                  'No playable movies tagged Short are available right now. Flix filters out query-only matches and series.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 22),
            OutlinedButton.icon(
              onPressed: () => _loadClips(refresh: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(30),
      child: SizedBox(
        width: 70,
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.48),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white38),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
