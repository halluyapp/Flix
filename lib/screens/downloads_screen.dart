import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/offline_download.dart';
import '../services/download_engine.dart';
import '../services/download_service.dart';
import 'player_screen.dart';

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
          '${job.displayTitle} and its saved subtitles will be deleted from '
          'this device.',
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
          '${jobs.length} downloaded item(s) and their subtitle files will be '
          'removed from this device. This cannot be undone.',
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
                            for (final job in active) _DownloadCard(
                              job: job,
                              onDelete: () => _confirmDelete(job),
                              onRetry: () => _run(() => service.retry(job)),
                              onCancel: () => _run(() => service.cancel(job)),
                            ),
                          ],
                          if (completed.isNotEmpty) ...[
                            const _SectionHeader('DOWNLOADED'),
                            ..._buildCompletedGroups(context, service, completed),
                          ],
                          if (failed.isNotEmpty) ...[
                            const _SectionHeader('FAILED'),
                            for (final job in failed) _DownloadCard(
                              job: job,
                              onDelete: () => _confirmDelete(job),
                              onRetry: () => _run(() => service.retry(job)),
                              onCancel: () => _run(() => service.cancel(job)),
                            ),
                          ],
                          const SizedBox(height: 14),
                          const Text(
                            'Downloads are stored privately inside Flix and are '
                            'never added to your public gallery. Offline playback '
                            'does not contact the provider.',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
        );
      },
    );
  }

  List<Widget> _buildCompletedGroups(
    BuildContext context,
    DownloadService service,
    List<OfflineDownload> completed,
  ) {
    final groups = <String, List<OfflineDownload>>{};
    for (final job in completed) {
      final key = job.isEpisode
          ? '${job.item.title}::${job.season}'
          : 'movie::${job.item.id}::${job.key}';
      groups.putIfAbsent(key, () => <OfflineDownload>[]).add(job);
    }
    final sortedKeys = groups.keys.toList()..sort();
    final widgets = <Widget>[];
    for (final key in sortedKeys) {
      final jobs = groups[key]!
        ..sort((a, b) {
          final season = a.season.compareTo(b.season);
          if (season != 0) return season;
          return a.episode.compareTo(b.episode);
        });
      final first = jobs.first;
      if (first.isEpisode) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
            child: Text(
              '${first.item.title} · Season ${first.season}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      }
      for (final job in jobs) {
        widgets.add(
          _DownloadCard(
            job: job,
            onDelete: () => _confirmDelete(job),
            onRetry: () => _run(() => service.retry(job)),
            onCancel: () => _run(() => service.cancel(job)),
            onRetrySubtitles: () =>
                _run(() => service.retrySubtitles(job).then((_) {})),
          ),
        );
      }
    }
    return widgets;
  }

  Widget _storageCard(DownloadService service, List<OfflineDownload> completed) {
    final movies = completed.where((job) => !job.isEpisode).length;
    final episodes = completed.where((job) => job.isEpisode).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2C2C2C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sd_storage_outlined,
                  color: _accent, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Offline storage',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
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
          const SizedBox(height: 6),
          Text(
            '$movies movie${movies == 1 ? '' : 's'} · '
            '$episodes episode${episodes == 1 ? '' : 's'}'
            '${_storage != null && _storage!.isKnown ? ' · ${_storage!.freeLabel} free on this device' : ''}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (service.supportsDownloads && !service.supportsPauseResume)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Downloads run in Android\'s background download manager. '
                'Pausing is not supported by this engine, so Flix offers restart '
                'instead of a fake pause button.',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  height: 1.4,
                ),
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
              Icon(Icons.download_for_offline_outlined,
                  color: Colors.white30, size: 58),
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
                'Open a movie or episode and choose Download. Flix saves the '
                'video together with the subtitles you pick so both work in '
                'airplane mode.',
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

class _DownloadCard extends StatelessWidget {
  final OfflineDownload job;
  final VoidCallback onDelete;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final VoidCallback? onRetrySubtitles;

  const _DownloadCard({
    required this.job,
    required this.onDelete,
    required this.onRetry,
    required this.onCancel,
    this.onRetrySubtitles,
  });

  bool get _fileExists => File(job.filePath).existsSync();

  bool get _subtitleMissing =>
      job.subtitleLanguages.length > job.subtitles.length;

  @override
  Widget build(BuildContext context) {
    final missingFile = job.isComplete && !_fileExists;
    final progress = job.progress;
    final percent = (progress * 100).clamp(0, 100).round();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2B2B2B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CachedNetworkImage(
              imageUrl: job.item.posterUrl,
              width: 76,
              height: 108,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                width: 76,
                height: 108,
                color: Colors.white10,
              ),
              errorWidget: (_, __, ___) => Container(
                width: 76,
                height: 108,
                color: Colors.white10,
                child: const Icon(Icons.movie_outlined, color: Colors.white38),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.isEpisode ? job.episodeTitle.isEmpty
                      ? job.episodeLabel
                      : '${job.episodeLabel} · ${job.episodeTitle}'
                      : job.item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  job.isEpisode ? job.item.title : 'Movie',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 11.5),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _chip(job.resolution),
                    _chip(
                      job.isComplete
                          ? 'Offline ready'
                          : job.status == 'failed'
                              ? 'Download interrupted'
                              : job.statusLabel,
                    ),
                    if (job.subtitles.isNotEmpty)
                      _chip(
                        '${job.subtitles.length} subtitle'
                        '${job.subtitles.length == 1 ? '' : 's'} · '
                        '${job.subtitleSummary}',
                        highlight: true,
                      ),
                    if (missingFile) _chip('File missing', danger: true),
                  ],
                ),
                const SizedBox(height: 8),
                if (job.isProcessing) ...[
                  LinearProgressIndicator(
                    value: job.totalBytes > 0 ? job.progress : null,
                    minHeight: 3.5,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation(_accent),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    job.totalBytes > 0
                        ? '$percent% · ${_formatBytes(job.downloadedBytes)} of '
                            '${_formatBytes(job.totalBytes)}'
                        : 'Waiting for the provider to report a size…',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      TextButton(
                        onPressed: onCancel,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32),
                          foregroundColor: Colors.white70,
                        ),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ] else if (job.isFailed || missingFile) ...[
                  Text(
                    missingFile
                        ? 'The video file was removed from this device. Delete '
                            'this entry and download it again.'
                        : (job.failureMessage ??
                            'This download did not finish.'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFFF9A9A),
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (!missingFile)
                        OutlinedButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh, size: 15),
                          label: const Text('Restart'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 32),
                          ),
                        ),
                      if (missingFile)
                        OutlinedButton(
                          onPressed: onDelete,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                            minimumSize: const Size(0, 32),
                          ),
                          child: const Text('Remove entry'),
                        ),
                    ],
                  ),
                ] else ...[
                  if (_subtitleMissing)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Text(
                        'Subtitles could not be saved for this copy.',
                        style: TextStyle(
                          color: Color(0xFFFFC46B),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlayerScreen(
                              item: job.item,
                              startSeason: job.season,
                              startEpisode: job.episode,
                              offlineFilePath: job.filePath,
                              offlineSubtitles: job.subtitles,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 16),
                        label: const Text('Play offline'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 33),
                        ),
                      ),
                      if (_subtitleMissing && onRetrySubtitles != null)
                        TextButton(
                          onPressed: onRetrySubtitles,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                            minimumSize: const Size(0, 33),
                          ),
                          child: const Text(
                            'Retry subtitles',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Download options',
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: const Color(0xFF303030),
            onSelected: (value) {
              switch (value) {
                case 'cancel':
                  onCancel();
                  break;
                case 'retry':
                  onRetry();
                  break;
                case 'subtitles':
                  onRetrySubtitles?.call();
                  break;
                case 'delete':
                  onDelete();
                  break;
              }
            },
            itemBuilder: (_) => [
              if (job.isProcessing)
                const PopupMenuItem(
                  value: 'cancel',
                  child: Text('Cancel download'),
                ),
              if (job.isFailed)
                const PopupMenuItem(value: 'retry', child: Text('Restart')),
              if (job.isComplete && onRetrySubtitles != null)
                const PopupMenuItem(
                  value: 'subtitles',
                  child: Text('Retry subtitles'),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete from device'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, {bool highlight = false, bool danger = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: danger
            ? const Color(0xFF3A1A1A)
            : highlight
                ? const Color(0xFF1E3323)
                : Colors.white10,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: danger
              ? const Color(0xFFFF9A9A)
              : highlight
                  ? const Color(0xFF7FE29A)
                  : Colors.white70,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
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
