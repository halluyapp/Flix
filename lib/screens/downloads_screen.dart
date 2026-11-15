import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/offline_download.dart';
import '../services/download_engine.dart';
import '../services/download_service.dart';
import '../services/user_state_service.dart';
import 'player_screen.dart';
import '../services/device_profile.dart';

const Color _accent = Color(0xFFE50914);

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  DownloadStorageInfo? _storage;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  Future<void> _refreshAll() async {
    final service = context.read<DownloadService>();
    await service.refreshStatuses();
    final storage = await service.storageInfo();
    if (!mounted) return;
    setState(() => _storage = storage);
  }

  Future<void> _confirmDelete(OfflineDownload job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text(
          'Remove download?',
          style: TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: Text(
          '${job.displayTitle} and its saved subtitles will be deleted from this device.',
          style: const TextStyle(color: Colors.white70, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFFF6B6B)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() => context.read<DownloadService>().delete(job));
  }

  Future<void> _confirmDeleteSeries(String seriesTitle, List<OfflineDownload> jobs) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: Text(
          'Delete $seriesTitle?',
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: Text(
          'All ${jobs.length} downloaded episode(s) and subtitles will be removed.',
          style: const TextStyle(color: Colors.white70, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Delete all',
              style: TextStyle(color: Color(0xFFFF6B6B)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    for (final job in jobs) {
      await context.read<DownloadService>().delete(job);
    }
    await _refreshAll();
  }

  Future<void> _confirmDeleteAll(List<OfflineDownload> jobs) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text(
          'Delete all downloads?',
          style: TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: Text(
          '${jobs.length} downloaded item(s) and their subtitle files will be removed from this device.',
          style: const TextStyle(color: Colors.white70, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Delete all',
              style: TextStyle(color: Color(0xFFFF6B6B)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<DownloadService>().deleteAll();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refreshAll();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Bad state: ', '')),
          backgroundColor: const Color(0xFF262626),
        ),
      );
    }
    await _refreshAll();
  }

  void _playDownload(OfflineDownload job) {
    if (!File(job.filePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File was moved or deleted from this device.'),
          backgroundColor: Color(0xFF262626),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: job.item,
          startSeason: job.season,
          startEpisode: job.episode,
          offlineFilePath: job.filePath,
          offlineSubtitles: job.subtitles,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DownloadService>(
      builder: (context, service, _) {
        final jobs = service.downloads;
        final active = service.activeDownloads;
        final completed = service.completedDownloads;
        final failed = service.failedDownloads;

        return Scaffold(
          backgroundColor: const Color(0xFF141414),
          appBar: AppBar(
            backgroundColor: const Color(0xFF141414),
            elevation: 0,
            leading: IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: const Text(
              'Downloads',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            actions: [
              if (jobs.isNotEmpty)
                IconButton(
                  tooltip: 'Refresh downloads',
                  onPressed: _busy ? null : _refreshAll,
                  icon: const Icon(Icons.refresh),
                ),
              if (completed.isNotEmpty)
                PopupMenuButton<String>(
                  color: const Color(0xFF262626),
                  onSelected: (value) {
                    if (value == 'delete_all') {
                      _confirmDeleteAll(completed);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'delete_all',
                      child: Text('Delete all downloads'),
                    ),
                  ],
                ),
            ],
          ),
          body: service.error != null && jobs.isEmpty
              ? _messageState(service.error!, Icons.error_outline)
              : jobs.isEmpty
                  ? _emptyState()
                  : RefreshIndicator(
                      onRefresh: _refreshAll,
                      color: _accent,
                      backgroundColor: const Color(0xFF262626),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
                        children: [
                          _storageCard(service, completed),
                          if (active.isNotEmpty) ...[
                            const _SectionHeader('DOWNLOADING'),
                            for (final job in active)
                              _ActiveDownloadTile(
                                job: job,
                                onCancel: () => _run(() => service.cancel(job)),
                              ),
                          ],
                          if (completed.isNotEmpty) ...[
                            const _SectionHeader('DOWNLOADED'),
                            ..._buildCompletedItems(context, service, completed),
                          ],
                          if (failed.isNotEmpty) ...[
                            const _SectionHeader('NEEDS ATTENTION'),
                            for (final job in failed)
                              _FailedDownloadTile(
                                job: job,
                                onRetry: () => _run(() => service.retry(job)),
                                onDelete: () => _confirmDelete(job),
                              ),
                          ],
                        ],
                      ),
                    ),
        );
      },
    );
  }

  List<Widget> _buildCompletedItems(
    BuildContext context,
    DownloadService service,
    List<OfflineDownload> completed,
  ) {
    // Separate TV series into collections and movies as standalone items
    final seriesMap = <int, List<OfflineDownload>>{};
    final movieDownloads = <OfflineDownload>[];

    for (final job in completed) {
      if (job.isEpisode) {
        seriesMap.putIfAbsent(job.item.id, () => <OfflineDownload>[]).add(job);
      } else {
        movieDownloads.add(job);
      }
    }

    final widgets = <Widget>[];

    // Series collections first
    for (final entry in seriesMap.entries) {
      final episodes = entry.value
        ..sort((a, b) {
          final s = a.season.compareTo(b.season);
          if (s != 0) return s;
          return a.episode.compareTo(b.episode);
        });
      widgets.add(
        _SeriesCollectionCard(
          seriesTitle: episodes.first.item.title,
          episodes: episodes,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SeriesDownloadsScreen(
                  item: episodes.first.item,
                  episodes: episodes,
                  onPlay: _playDownload,
                  onDeleteEpisode: _confirmDelete,
                  onDeleteAll: () => _confirmDeleteSeries(episodes.first.item.title, episodes),
                ),
              ),
            ).then((_) => _refreshAll());
          },
          onPlayNext: () {
            // Pick next unwatched or first
            final userState = context.read<UserStateService>();
            OfflineDownload? target;
            for (final ep in episodes) {
              final prog = userState.progressFor(
                ep.item,
                season: ep.season,
                episode: ep.episode,
              );
              if (prog == null || !prog.isCompleted) {
                target = ep;
                break;
              }
            }
            target ??= episodes.first;
            _playDownload(target);
          },
          onDelete: () => _confirmDeleteSeries(episodes.first.item.title, episodes),
        ),
      );
    }

    // Movies
    for (final job in movieDownloads) {
      widgets.add(
        _MovieDownloadCard(
          job: job,
          onPlay: () => _playDownload(job),
          onDelete: () => _confirmDelete(job),
        ),
      );
    }

    return widgets;
  }

  Widget _storageCard(DownloadService service, List<OfflineDownload> completed) {
    final movies = completed.where((job) => !job.isEpisode).length;
    final episodes = completed.where((job) => job.isEpisode).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2C2C2C)),
      ),
      child: Row(
        children: [
          const Icon(Icons.sd_storage_outlined, color: _accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$movies movie${movies == 1 ? '' : 's'} · $episodes episode${episodes == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_storage != null && _storage!.isKnown)
                  Text(
                    '${_storage!.freeLabel} free on device',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
              ],
            ),
          ),
          Text(
            _formatBytes(service.usedBytes),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_for_offline_outlined, color: Colors.white30, size: 58),
              SizedBox(height: 18),
              Text(
                'Nothing downloaded yet',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Movies and TV series you download will appear here for offline viewing anytime, even without an internet connection.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, height: 1.45),
              ),
            ],
          ),
        ),
      );

  Widget _messageState(String message, IconData icon) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white38, size: 48),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white60),
              ),
            ],
          ),
        ),
      );
}

/// Netflix-style Series Collection Card
class _SeriesCollectionCard extends StatelessWidget {
  final String seriesTitle;
  final List<OfflineDownload> episodes;
  final VoidCallback onTap;
  final VoidCallback onPlayNext;
  final VoidCallback onDelete;

  const _SeriesCollectionCard({
    required this.seriesTitle,
    required this.episodes,
    required this.onTap,
    required this.onPlayNext,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final first = episodes.first;
    final totalBytes = episodes.fold<int>(0, (sum, ep) => sum + ep.totalBytes);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2B2B2B)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Stacked poster effect with play overlay
                Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                        imageUrl: first.item.posterUrl,
                        memCacheWidth: DeviceProfile.instance.posterDecodeWidth,
                        width: 74,
                        height: 104,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          width: 74,
                          height: 104,
                          color: Colors.white10,
                          child: const Icon(Icons.movie_outlined, color: Colors.white38),
                        ),
                      ),
                    ),
                    // Circular play button on poster
                    GestureDetector(
                      onTap: onPlayNext,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                // Title and episode count
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        seriesTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${episodes.length} Episode${episodes.length == 1 ? '' : 's'} · ${_formatBytes(totalBytes)}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'Series Collection',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white54,
                  size: 28,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Netflix-style Movie Card
class _MovieDownloadCard extends StatelessWidget {
  final OfflineDownload job;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  const _MovieDownloadCard({
    required this.job,
    required this.onPlay,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final userState = context.watch<UserStateService>();
    final progress = userState.progressFor(job.item);
    final hasProgress = progress != null && progress.positionSeconds > 0 && !progress.isCompleted;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2B2B2B)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPlay,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Poster with Play button overlay & auto-resume progress bar
                Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                        imageUrl: job.item.posterUrl,
                        memCacheWidth: DeviceProfile.instance.posterDecodeWidth,
                        width: 74,
                        height: 104,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          width: 74,
                          height: 104,
                          color: Colors.white10,
                          child: const Icon(Icons.movie_outlined, color: Colors.white38),
                        ),
                      ),
                    ),
                    // Circular play button
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.65),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    if (hasProgress)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
                          child: LinearProgressIndicator(
                            value: progress.progressFraction,
                            minHeight: 3.5,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation(_accent),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                // Details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${job.resolution} · ${_formatBytes(job.totalBytes)}',
                        style: const TextStyle(color: Colors.white60, fontSize: 12.5),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (hasProgress)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: _accent.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Resume ${progress.positionSeconds ~/ 60}m',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (job.subtitles.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E3323),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                job.subtitleSummary,
                                style: const TextStyle(
                                  color: Color(0xFF7FE29A),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.white70),
                  color: const Color(0xFF303030),
                  onSelected: (value) {
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete download'),
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
}

/// Detail view for all downloaded episodes inside a Series Collection
class SeriesDownloadsScreen extends StatelessWidget {
  final dynamic item;
  final List<OfflineDownload> episodes;
  final ValueChanged<OfflineDownload> onPlay;
  final ValueChanged<OfflineDownload> onDeleteEpisode;
  final VoidCallback onDeleteAll;

  const SeriesDownloadsScreen({
    super.key,
    required this.item,
    required this.episodes,
    required this.onPlay,
    required this.onDeleteEpisode,
    required this.onDeleteAll,
  });

  @override
  Widget build(BuildContext context) {
    // Group by Season
    final seasons = <int, List<OfflineDownload>>{};
    for (final ep in episodes) {
      seasons.putIfAbsent(ep.season, () => <OfflineDownload>[]).add(ep);
    }
    final sortedSeasons = seasons.keys.toList()..sort();

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141414),
        elevation: 0,
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          item.title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          PopupMenuButton<String>(
            color: const Color(0xFF262626),
            onSelected: (value) {
              if (value == 'delete_all') {
                onDeleteAll();
                Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'delete_all',
                child: Text('Delete all from ${item.title}'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          for (final seasonNum in sortedSeasons) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Text(
                'SEASON $seasonNum',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            for (final ep in seasons[seasonNum]!)
              _EpisodeDownloadTile(
                job: ep,
                onPlay: () => onPlay(ep),
                onDelete: () => onDeleteEpisode(ep),
              ),
          ],
        ],
      ),
    );
  }
}

class _EpisodeDownloadTile extends StatelessWidget {
  final OfflineDownload job;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  const _EpisodeDownloadTile({
    required this.job,
    required this.onPlay,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final userState = context.watch<UserStateService>();
    final progress = userState.progressFor(
      job.item,
      season: job.season,
      episode: job.episode,
    );
    final hasProgress = progress != null && progress.positionSeconds > 0 && !progress.isCompleted;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2B2B2B)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPlay,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Thumbnail with play button overlay
                Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                        imageUrl: job.item.posterUrl,
                        memCacheWidth: DeviceProfile.instance.posterDecodeWidth,
                        width: 82,
                        height: 52,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          width: 82,
                          height: 52,
                          color: Colors.white10,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.65),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.2),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    if (hasProgress)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
                          child: LinearProgressIndicator(
                            value: progress.progressFraction,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation(_accent),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.episodeTitle.isEmpty
                            ? 'Episode ${job.episode}'
                            : '${job.episode}. ${job.episodeTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${job.resolution} · ${_formatBytes(job.totalBytes)}',
                        style: const TextStyle(color: Colors.white54, fontSize: 11.5),
                      ),
                      if (hasProgress)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            'Resume ${progress.positionSeconds ~/ 60}m of ${progress.durationSeconds ~/ 60}m',
                            style: const TextStyle(
                              color: _accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Delete episode',
                  icon: const Icon(Icons.delete_outline, color: Colors.white54, size: 20),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveDownloadTile extends StatelessWidget {
  final OfflineDownload job;
  final VoidCallback onCancel;

  const _ActiveDownloadTile({required this.job, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final progress = job.progress;
    final percent = (progress * 100).clamp(0, 100).round();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2B2B2B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  job.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Cancel',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.close, color: Colors.white60, size: 18),
                onPressed: onCancel,
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: job.totalBytes > 0 ? job.progress : null,
            minHeight: 4,
            backgroundColor: Colors.white12,
            valueColor: const AlwaysStoppedAnimation(_accent),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                job.totalBytes > 0
                    ? '$percent% · ${_formatBytes(job.downloadedBytes)} of ${_formatBytes(job.totalBytes)}'
                    : 'Connecting to provider…',
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
              Text(
                job.resolution,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FailedDownloadTile extends StatelessWidget {
  final OfflineDownload job;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  const _FailedDownloadTile({
    required this.job,
    required this.onRetry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF241818),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3D2222)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF6B6B), size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  job.failureMessage ?? 'Download interrupted',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFFF9A9A), fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Retry',
            icon: const Icon(Icons.refresh, color: Colors.white, size: 20),
            onPressed: onRetry,
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, color: Colors.white54, size: 20),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;

  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
