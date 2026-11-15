import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/tv_season.dart';
import '../services/download_service.dart';
import '../services/tmdb_service.dart';
import '../services/user_state_service.dart';
import '../widgets/content_rail.dart';
import 'download_options_sheet.dart';
import 'player_screen.dart';

const Color _accent = Color(0xFFE50914);

class DetailScreen extends StatefulWidget {
  final MediaItem item;

  const DetailScreen({super.key, required this.item});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final TmdbService _tmdbService = TmdbService();
  List<TvSeason> _seasons = const [];
  List<Episode> _episodes = const [];
  List<MediaItem> _similar = const [];
  int _selectedSeason = 1;
  int _seasonGeneration = 0;
  bool _isLoadingEpisodes = false;

  bool get _isSeries => widget.item.mediaType == 'tv';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (_isSeries) {
      await _loadSeasons();
    }
    try {
      final similar = await _tmdbService.getByGenre(
        widget.item.genreIds.isNotEmpty ? widget.item.genreIds.first : 28,
        isTv: _isSeries,
      );
      if (mounted) setState(() => _similar = similar);
    } catch (_) {}
  }

  Future<void> _loadSeasons() async {
    List<TvSeason> seasons = const [];
    try {
      seasons = await _tmdbService.getSeasons(widget.item.id);
    } catch (_) {}
    if (!mounted) return;
    final playable = seasons
        .where((season) => season.hasEpisodes)
        .toList(growable: false);
    final firstSeason = playable.isNotEmpty
        ? playable.firstWhere(
            (season) => season.seasonNumber > 0,
            orElse: () => playable.first,
          )
        : null;
    setState(() {
      _seasons = playable;
      _selectedSeason = firstSeason?.seasonNumber ?? 1;
    });
    await _loadSeasonEpisodes(_selectedSeason);
  }

  Future<void> _loadSeasonEpisodes(int season) async {
    final generation = ++_seasonGeneration;
    setState(() => _isLoadingEpisodes = true);
    List<Episode> episodes = const [];
    try {
      episodes = await _tmdbService.getSeasonEpisodes(widget.item.id, season);
    } catch (_) {}
    if (!mounted || generation != _seasonGeneration) return;
    setState(() {
      _episodes = episodes;
      _selectedSeason = season;
      _isLoadingEpisodes = false;
    });
  }

  Future<void> _openMovieDownload() async {
    final started = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DownloadOptionsSheet(item: widget.item),
    );
    _afterDownloadSheet(started);
  }

  Future<void> _openEpisodeDownload(Episode episode) async {
    final started = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DownloadOptionsSheet(
        item: widget.item,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
        episodeTitle: episode.name,
      ),
    );
    _afterDownloadSheet(started);
  }

  Future<void> _openSeasonDownload() async {
    if (_episodes.isEmpty) return;
    final season = _seasons.firstWhere(
      (entry) => entry.seasonNumber == _selectedSeason,
      orElse: () => TvSeason(
        seasonNumber: _selectedSeason,
        name: 'Season $_selectedSeason',
        episodeCount: _episodes.length,
      ),
    );
    final started = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SeasonDownloadSheet(
        item: widget.item,
        season: season,
        episodes: _episodes,
      ),
    );
    _afterDownloadSheet(started);
  }

  void _afterDownloadSheet(bool? started) {
    if (started != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Added to Downloads. Open My Flix → Downloads.'),
        backgroundColor: Color(0xFF262626),
      ),
    );
  }

  Future<void> _shareTitle() async {
    try {
      await Share.share(
        '${widget.item.title}${widget.item.releaseYear > 0 ? ' (${widget.item.releaseYear})' : ''} on Flix',
      );
    } catch (_) {}
  }

  void _play({Episode? episode}) {
    final season = episode?.seasonNumber ??
        (_isSeries ? _selectedSeason : 0);
    final episodeNumber = episode?.episodeNumber ??
        (_isSeries && _episodes.isNotEmpty ? _episodes.first.episodeNumber : 0);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: widget.item,
          startSeason: season > 0 ? season : 1,
          startEpisode: episodeNumber > 0 ? episodeNumber : 1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userState = Provider.of<UserStateService>(context);
    final downloadService = context.watch<DownloadService>();
    final inMyList = userState.isInMyList(widget.item);

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share, color: Colors.white),
            onPressed: _shareTitle,
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                CachedNetworkImage(
                  imageUrl: widget.item.backdropUrl,
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(
                    height: 220,
                    color: const Color(0xFF1B1B1B),
                  ),
                ),
                Container(
                  height: 220,
                  color: Colors.black.withValues(alpha: 0.35),
                ),
                GestureDetector(
                  onTap: () => _play(),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.item.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (widget.item.voteAverage > 0) ...[
                        const Icon(Icons.star, color: Color(0xFFE5B409), size: 14),
                        const SizedBox(width: 4),
                        Text(
                          widget.item.voteAverage.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (widget.item.releaseYear > 0) ...[
                        Text(
                          '${widget.item.releaseYear}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF333333),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          _isSeries ? 'SERIES' : 'FILM',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: () => _play(),
                      icon: const Icon(
                        Icons.play_arrow,
                        color: Colors.black,
                        size: 26,
                      ),
                      label: const Text(
                        'Play',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: _isSeries
                          ? _openSeasonDownload
                          : _openMovieDownload,
                      icon: const Icon(Icons.download, size: 20),
                      label: Text(
                        _isSeries ? 'Download episodes' : 'Download',
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: const Color(0xFF262626),
                        side: const BorderSide(color: Colors.white12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  if (!downloadService.supportsDownloads)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Offline downloads are available in the Android build.',
                        style: TextStyle(color: Colors.white38, fontSize: 11.5),
                      ),
                    ),
                  const SizedBox(height: 14),
                  Text(
                    widget.item.overview,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      GestureDetector(
                        onTap: () => userState.toggleMyList(widget.item),
                        child: Column(
                          children: [
                            Icon(
                              inMyList ? Icons.check : Icons.add,
                              color: Colors.white,
                              size: 26,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              inMyList ? 'In List' : 'My List',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: _shareTitle,
                        child: const Column(
                          children: [
                            Icon(Icons.share, color: Colors.white, size: 24),
                            SizedBox(height: 4),
                            Text(
                              'Share',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2B2B2B), thickness: 1),
            if (_isSeries) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    if (_seasons.isNotEmpty)
                      DropdownButton<int>(
                        value: _seasons.any(
                          (season) => season.seasonNumber == _selectedSeason,
                        )
                            ? _selectedSeason
                            : _seasons.first.seasonNumber,
                        dropdownColor: const Color(0xFF1F1F1F),
                        underline: const SizedBox.shrink(),
                        icon: const Icon(
                          Icons.arrow_drop_down,
                          color: Colors.white,
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        items: [
                          for (final season in _seasons)
                            DropdownMenuItem(
                              value: season.seasonNumber,
                              child: Text(season.label),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) _loadSeasonEpisodes(value);
                        },
                      )
                    else
                      const Text(
                        'Episodes',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    const Spacer(),
                    if (_episodes.isNotEmpty)
                      TextButton.icon(
                        onPressed: _openSeasonDownload,
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text(
                          'Download season',
                          style: TextStyle(fontSize: 12.5),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white70,
                        ),
                      ),
                  ],
                ),
              ),
              if (_isLoadingEpisodes)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(color: _accent),
                  ),
                )
              else if (_episodes.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'TMDB has no episode data for this season yet.',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _episodes.length,
                  itemBuilder: (context, index) {
                    final episode = _episodes[index];
                    final download = downloadService.downloadStateFor(
                      widget.item,
                      season: episode.seasonNumber,
                      episode: episode.episodeNumber,
                    );
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: CachedNetworkImage(
                          imageUrl: episode.thumbnail,
                          width: 100,
                          height: 60,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            width: 100,
                            height: 60,
                            color: Colors.white10,
                          ),
                        ),
                      ),
                      title: Text(
                        '${episode.episodeNumber}. ${episode.name}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        [
                          '${episode.runtime}m',
                          if (download != null)
                            download.isComplete
                                ? 'Downloaded · ${download.resolution}'
                                : download.isProcessing
                                    ? 'Downloading…'
                                    : 'Download failed',
                        ].join(' · '),
                        style: TextStyle(
                          color: download?.isComplete == true
                              ? const Color(0xFF46D369)
                              : Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                      trailing: download != null && download.isComplete
                          ? IconButton(
                              tooltip: 'Play downloaded episode',
                              icon: const Icon(
                                Icons.download_done,
                                color: Color(0xFF46D369),
                              ),
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => PlayerScreen(
                                      item: widget.item,
                                      startSeason: download.season,
                                      startEpisode: download.episode,
                                      offlineFilePath: download.filePath,
                                      offlineSubtitles: download.subtitles,
                                    ),
                                  ),
                                );
                              },
                            )
                          : IconButton(
                              tooltip: 'Download episode',
                              icon: Icon(
                                Icons.download_for_offline_outlined,
                                color: download?.isProcessing == true
                                    ? _accent
                                    : Colors.white70,
                              ),
                              onPressed: () => _openEpisodeDownload(episode),
                            ),
                      onTap: () => _play(episode: episode),
                    );
                  },
                ),
            ],
            const SizedBox(height: 10),
            ContentRail(title: 'More Like This', items: _similar),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
