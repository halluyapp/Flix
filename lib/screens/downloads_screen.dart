import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/offline_download.dart';
import '../services/download_service.dart';
import 'player_screen.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<DownloadService>(
      builder: (context, service, _) {
        final jobs = service.downloads;
        return Scaffold(
          backgroundColor: const Color(0xFF141414),
          appBar: AppBar(
            backgroundColor: const Color(0xFF141414),
            elevation: 0,
            leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop()),
            title: const Text('My Downloads',
                style: TextStyle(fontWeight: FontWeight.w700)),
            actions: [
              if (jobs.isNotEmpty)
                IconButton(
                  tooltip: 'Refresh downloads',
                  onPressed: service.refreshStatuses,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
          body: service.error != null && jobs.isEmpty
              ? _message(service.error!, Icons.error_outline)
              : jobs.isEmpty
                  ? _emptyState()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                      children: [
                        const Text('WATCH OFFLINE',
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.4)),
                        const SizedBox(height: 12),
                        for (final job in jobs) _DownloadCard(job: job),
                        const SizedBox(height: 12),
                        const Text(
                            'Downloads are saved privately in this app and are not added to your public gallery.',
                            style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                                height: 1.45)),
                      ],
                    ),
        );
      },
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
              Text('Your offline library is ready.',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              SizedBox(height: 8),
              Text(
                  'Choose Download on a movie or episode. Your video and selected subtitles will stay inside Flix.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, height: 1.4)),
            ],
          ),
        ),
      );

  Widget _message(String message, IconData icon) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white38, size: 48),
              const SizedBox(height: 14),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60)),
            ],
          ),
        ),
      );
}

class _DownloadCard extends StatelessWidget {
  final OfflineDownload job;

  const _DownloadCard({required this.job});

  Future<void> _runAction(BuildContext context, Future<void> action) async {
    try {
      await action;
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update this download: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.read<DownloadService>();
    final fileExists = job.isComplete && File(job.filePath).existsSync();
    final progressText = job.totalBytes > 0
        ? '${(job.progress * 100).round()}%'
        : (job.isActive ? 'Downloading' : '');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: const Color(0xFF202020),
          borderRadius: BorderRadius.circular(8)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Image.network(
              job.item.posterUrl,
              width: 78,
              height: 112,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                  width: 78,
                  height: 112,
                  color: Colors.white10,
                  child:
                      const Icon(Icons.movie_outlined, color: Colors.white38)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(job.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                    '${job.resolution} · ${job.subtitles.length} subtitle${job.subtitles.length == 1 ? '' : 's'}',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 10),
                if (job.isActive) ...[
                  LinearProgressIndicator(
                      value: job.totalBytes > 0 ? job.progress : null,
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                      valueColor:
                          const AlwaysStoppedAnimation(Color(0xFFE50914))),
                  const SizedBox(height: 6),
                  Text(progressText,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 11)),
                ] else if (job.status == 'failed') ...[
                  const Text('Download interrupted',
                      style: TextStyle(color: Color(0xFFFF7777), fontSize: 12)),
                  const SizedBox(height: 4),
                  TextButton.icon(
                      onPressed: () => _runAction(context, service.retry(job)),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Retry'),
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 30))),
                ] else if (fileExists) ...[
                  OutlinedButton.icon(
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => PlayerScreen(
                                  item: job.item,
                                  startSeason: job.season,
                                  startEpisode: job.episode,
                                  offlineFilePath: job.filePath,
                                  offlineSubtitles: job.subtitles,
                                ))),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Play offline'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 34)),
                  ),
                ] else ...[
                  Text(
                      job.status == 'completed'
                          ? 'File missing'
                          : 'Saved as ${job.status}',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: const Color(0xFF303030),
            onSelected: (value) {
              if (value == 'cancel') {
                _runAction(context, service.cancel(job));
              } else if (value == 'retry') {
                _runAction(context, service.retry(job));
              } else if (value == 'delete') {
                _runAction(context, service.delete(job));
              }
            },
            itemBuilder: (_) => [
              if (job.isActive)
                const PopupMenuItem(
                    value: 'cancel', child: Text('Cancel download')),
              if (job.status == 'failed')
                const PopupMenuItem(value: 'retry', child: Text('Try again')),
              const PopupMenuItem(
                  value: 'delete', child: Text('Remove from Flix')),
            ],
          ),
        ],
      ),
    );
  }
}
