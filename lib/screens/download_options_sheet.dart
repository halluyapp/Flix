import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../services/download_service.dart';
import '../services/stream_resolver.dart';

class DownloadOptionsSheet extends StatefulWidget {
  final MediaItem item;
  final int season;
  final int episode;
  final String episodeTitle;

  const DownloadOptionsSheet({
    super.key,
    required this.item,
    this.season = 0,
    this.episode = 0,
    this.episodeTitle = '',
  });

  @override
  State<DownloadOptionsSheet> createState() => _DownloadOptionsSheetState();
}

class _DownloadOptionsSheetState extends State<DownloadOptionsSheet> {
  ResolvedMediaStream? _resolved;
  StreamSource? _selectedSource;
  final Set<String> _selectedSubtitles = {};
  bool _loading = true;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final result = await context.read<DownloadService>().prepare(
            widget.item,
            season: widget.season,
            episode: widget.episode,
          );
      if (!mounted) return;
      final sources = result.downloadSources;
      final preferred = sources
          .where((source) => source.qualityValue <= 720)
          .toList()
        ..sort((a, b) => b.qualityValue.compareTo(a.qualityValue));
      final selected = preferred.isNotEmpty ? preferred.first : sources.last;
      setState(() {
        _resolved = result;
        _selectedSource = selected;
        _selectedSubtitles.addAll(result.captions.map((caption) => caption.id));
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _start() async {
    final resolved = _resolved;
    final source = _selectedSource;
    if (resolved == null || source == null || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await context.read<DownloadService>().startDownload(
            item: widget.item,
            season: widget.season,
            episode: widget.episode,
            episodeTitle: widget.episodeTitle,
            resolved: resolved,
            source: source,
            subtitleIds: _selectedSubtitles,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final resolved = _resolved;
    final sources = resolved?.downloadSources ?? const <StreamSource>[];
    final captions = resolved?.captions ?? const [];
    return SafeArea(
      top: false,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.82),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: _loading
              ? const SizedBox(
                  height: 250,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Color(0xFFE50914)),
                        SizedBox(height: 16),
                        Text('Preparing your offline copy…',
                            style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      widget.item.mediaType == 'tv'
                          ? '${widget.item.title} · S${widget.season}:E${widget.episode}'
                          : widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    const Text('Download to watch offline',
                        style: TextStyle(color: Colors.white60, fontSize: 13)),
                    const SizedBox(height: 18),
                    const Text('VIDEO QUALITY',
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1)),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final source in sources)
                            RadioListTile<StreamSource>(
                              value: source,
                              groupValue: _selectedSource,
                              onChanged: _starting
                                  ? null
                                  : (value) =>
                                      setState(() => _selectedSource = value),
                              activeColor: const Color(0xFFE50914),
                              contentPadding: EdgeInsets.zero,
                              title: Text(source.resolution,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                '${source.format.toUpperCase()}${source.sizeBytes > 0 ? ' · ${_formatSize(source.sizeBytes)}' : ''}',
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12),
                              ),
                            ),
                          const Divider(color: Colors.white12),
                          Row(
                            children: [
                              const Expanded(
                                  child: Text('SUBTITLES',
                                      style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 1))),
                              TextButton(
                                onPressed: _starting || captions.isEmpty
                                    ? null
                                    : () => setState(() {
                                          if (_selectedSubtitles.length ==
                                              captions.length) {
                                            _selectedSubtitles.clear();
                                          } else {
                                            _selectedSubtitles
                                              ..clear()
                                              ..addAll(captions.map(
                                                  (caption) => caption.id));
                                          }
                                        }),
                                child: Text(
                                    _selectedSubtitles.length == captions.length
                                        ? 'None'
                                        : 'All'),
                              ),
                            ],
                          ),
                          if (captions.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                  'No subtitles are available for this episode.',
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 12)),
                            )
                          else
                            for (final caption in captions)
                              CheckboxListTile(
                                value: _selectedSubtitles.contains(caption.id),
                                onChanged: _starting
                                    ? null
                                    : (checked) => setState(() {
                                          if (checked == true) {
                                            _selectedSubtitles.add(caption.id);
                                          } else {
                                            _selectedSubtitles
                                                .remove(caption.id);
                                          }
                                        }),
                                activeColor: const Color(0xFFE50914),
                                checkColor: Colors.white,
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(caption.languageName,
                                    style:
                                        const TextStyle(color: Colors.white)),
                              ),
                        ],
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: const TextStyle(
                              color: Color(0xFFFF7676), fontSize: 12)),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _starting || _selectedSource == null
                            ? null
                            : _start,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE50914),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6)),
                        ),
                        icon: _starting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.download_rounded),
                        label: Text(_starting
                            ? 'Starting download…'
                            : 'Download in Flix'),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Center(
                        child: Text(
                            'Your download and subtitles stay inside Flix.',
                            style: TextStyle(
                                color: Colors.white38, fontSize: 11))),
                  ],
                ),
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    if (bytes >= 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
