import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/provider/provider_failures.dart';
import '../core/provider/provider_messages.dart';
import '../models/caption_track.dart';
import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../models/tv_season.dart';
import '../services/download_engine.dart';
import '../services/download_service.dart';
import '../services/stream_resolver.dart';

const Color _accent = Color(0xFFE50914);
const Color _surface = Color(0xFF1A1A1A);

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
  PlaybackResolution? _resolution;
  StreamSource? _selectedSource;
  final Set<String> _selectedLanguages = <String>{};
  DownloadStorageInfo? _storage;
  bool _loading = true;
  bool _starting = false;
  bool _wifiOnly = false;
  String? _error;
  ProviderException? _failure;

  bool get _isSeries => widget.item.mediaType == 'tv';

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare({bool refresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _failure = null;
    });
    final service = context.read<DownloadService>();
    final resolution = await service.prepare(
      widget.item,
      season: widget.season,
      episode: widget.episode,
      forceRefresh: refresh,
    );
    final storage = await service.storageInfo();
    if (!mounted) return;

    if (!resolution.isSuccess) {
      setState(() {
        _loading = false;
        _failure = resolution.failure;
        _storage = storage;
      });
      return;
    }

    final sources = resolution.stream!.downloadSources;
    StreamSource? selected;
    if (sources.isNotEmpty) {
      final preferred = sources
          .where((source) => source.qualityValue > 0 && source.qualityValue <= 720)
          .toList()
        ..sort((a, b) => b.qualityValue.compareTo(a.qualityValue));
      selected = preferred.isNotEmpty ? preferred.first : sources.first;
    }

    final preferredLanguages = service.preferredSubtitleLanguages.toSet();
    final captions = resolution.stream!.captions;
    final chosen = <String>{};
    if (preferredLanguages.isNotEmpty) {
      for (final caption in captions) {
        if (preferredLanguages.contains(caption.language)) {
          chosen.add(caption.language);
        }
      }
    }
    if (chosen.isEmpty) {
      final defaults = captions.where((caption) => caption.isDefault);
      if (defaults.isNotEmpty) {
        chosen.add(defaults.first.language);
      }
    }

    setState(() {
      _resolution = resolution;
      _selectedSource = selected;
      _storage = storage;
      _wifiOnly = service.wifiOnly;
      _selectedLanguages
        ..clear()
        ..addAll(chosen);
      _loading = false;
    });
  }

  OfflineDownloadState get _existingState {
    final source = _selectedSource;
    if (source == null) return OfflineDownloadState.none;
    final service = context.read<DownloadService>();
    final existing = service.findDownload(
      widget.item,
      season: widget.season,
      episode: widget.episode,
      qualityValue: source.qualityValue,
    );
    if (existing == null) return OfflineDownloadState.none;
    return existing.isComplete
        ? OfflineDownloadState.complete
        : OfflineDownloadState.pending;
  }

  Future<void> _start() async {
    final resolution = _resolution;
    final source = _selectedSource;
    if (resolution == null || source == null || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    final service = context.read<DownloadService>();
    try {
      await service.setWifiOnly(_wifiOnly);
      if (_selectedLanguages.isNotEmpty) {
        await service.setPreferredSubtitleLanguages(
          _selectedLanguages.toList(growable: false),
        );
      }
      await service.startDownload(
        item: widget.item,
        season: widget.season,
        episode: widget.episode,
        episodeTitle: widget.episodeTitle,
        resolved: resolution.stream!,
        source: source,
        subtitleLanguages: _selectedLanguages,
        wifiOnly: _wifiOnly,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on DownloadConflictException catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = error.toString();
      });
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
    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.86,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        decoration: const BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: _loading ? _buildLoading() : _buildContent(),
      ),
    );
  }

  Widget _buildLoading() {
    return const SizedBox(
      height: 260,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: _accent),
            ),
            SizedBox(height: 16),
            Text(
              'Checking the provider for downloadable sources…',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final resolution = _resolution;
    final stream = resolution?.stream;
    final sources = stream?.downloadSources ?? const <StreamSource>[];
    final streamingOnly = stream?.streamingOnlySources ?? const <StreamSource>[];
    final captions = stream?.captions ?? const <CaptionTrack>[];
    final failure = _failure;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            _isSeries
                ? '${widget.item.title} · S${widget.season}:E${widget.episode}'
                : widget.item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (_isSeries && widget.episodeTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                widget.episodeTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 12.5),
              ),
            ),
          const SizedBox(height: 4),
          const Text(
            'Download to watch offline',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 16),

          if (failure != null) ...[
            _failureCard(failure),
            const SizedBox(height: 12),
          ],

          if (sources.isNotEmpty) ...[
            const _SectionLabel('VIDEO QUALITY'),
            for (final source in sources)
              RadioListTile<StreamSource>(
                value: source,
                groupValue: _selectedSource,
                onChanged: _starting
                    ? null
                    : (value) => setState(() => _selectedSource = value),
                activeColor: _accent,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  source.displayLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  source.sizeBytes > 0
                      ? '${source.sizeLabel}${source.codec.isEmpty ? '' : ' · ${source.codec}'}'
                      : 'Size unknown · reported by the provider only when available',
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
          ] else if (failure == null) ...[
            const _SectionLabel('VIDEO QUALITY'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF262626),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                streamingOnly.isNotEmpty
                    ? 'The provider only offers segmented streams for this title '
                        '(${streamingOnly.map((source) => source.format.toUpperCase()).toSet().join(', ')}). '
                        'Flix can stream them but cannot save them as one offline '
                        'file, so downloading is unavailable.'
                    : 'The provider has no downloadable MP4 source for this title '
                        'right now. You can still stream it.',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ),
          ],

          if (sources.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const Expanded(child: _SectionLabel('SUBTITLES')),
                TextButton(
                  onPressed: _starting ||
                          captions.isEmpty ||
                          _selectedLanguages.length == captions.length
                      ? null
                      : () => setState(() {
                            _selectedLanguages
                              ..clear()
                              ..addAll(captions.map((c) => c.language));
                          }),
                  child: const Text(
                    'All',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                TextButton(
                  onPressed:
                      _starting || _selectedLanguages.isEmpty
                          ? null
                          : () => setState(_selectedLanguages.clear),
                  child: const Text(
                    'None',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
            if (captions.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'No downloadable subtitle was found for this title. The video '
                  'can still be downloaded.',
                  style: TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
              )
            else
              for (final caption in captions)
                CheckboxListTile(
                  value: _selectedLanguages.contains(caption.language),
                  onChanged: _starting
                      ? null
                      : (checked) => setState(() {
                            if (checked == true) {
                              _selectedLanguages.add(caption.language);
                            } else {
                              _selectedLanguages.remove(caption.language);
                            }
                          }),
                  activeColor: _accent,
                  checkColor: Colors.white,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    caption.languageName,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    caption.extension.toUpperCase(),
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
            if (captions.isNotEmpty && _selectedLanguages.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  'No subtitles selected. Video still downloads without them.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF242424),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.wifi, color: Colors.white70),
                    title: const Text(
                      'Wi-Fi only',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: const Text(
                      'Do not use mobile data for downloads',
                      style: TextStyle(color: Colors.white54, fontSize: 11.5),
                    ),
                    value: _wifiOnly,
                    activeColor: _accent,
                    onChanged: _starting
                        ? null
                        : (value) => setState(() => _wifiOnly = value),
                  ),
                  if (_storage != null && _storage!.isKnown)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.sd_storage_outlined,
                              color: Colors.white54, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${_storage!.freeLabel} free on this device · '
                              'Flix is using ${_formatBytes(context.read<DownloadService>().usedBytes)}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],

          if (_existingState != OfflineDownloadState.none)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2118),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF5A4322)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.download_done,
                        color: Color(0xFFFFC46B), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _existingState == OfflineDownloadState.complete
                            ? 'This quality is already downloaded and ready offline.'
                            : 'This quality is already in your downloads queue.',
                        style: const TextStyle(
                          color: Color(0xFFFFD9A0),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: Color(0xFFFF8080), fontSize: 12.5),
            ),
          ],

          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _starting || _selectedSource == null ||
                      _existingState != OfflineDownloadState.none
                  ? null
                  : _start,
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF3A3A3A),
                disabledForegroundColor: Colors.white38,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(
                _starting
                    ? 'Starting download…'
                    : _existingState == OfflineDownloadState.complete
                        ? 'Already downloaded'
                        : _existingState == OfflineDownloadState.pending
                            ? 'Already queued'
                            : 'Download in Flix',
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Video and selected subtitles are stored privately inside Flix.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
          if (failure != null)
            Center(
              child: TextButton(
                onPressed: _starting ? null : () => unawaited(_prepare(refresh: true)),
                child: const Text(
                  'Check again',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _failureCard(ProviderException failure) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1A1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF5A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ProviderMessages.titleFor(failure.type),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ProviderMessages.bodyFor(failure.type),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

enum OfflineDownloadState { none, pending, complete }

/// Batch download sheet for a full season or a hand-picked set of episodes.
///
/// Episodes are resolved and started one at a time so cancelling a batch never
/// corrupts episodes that already completed.
class SeasonDownloadSheet extends StatefulWidget {
  final MediaItem item;
  final TvSeason season;
  final List<Episode> episodes;

  const SeasonDownloadSheet({
    super.key,
    required this.item,
    required this.season,
    required this.episodes,
  });

  @override
  State<SeasonDownloadSheet> createState() => _SeasonDownloadSheetState();
}

class _SeasonDownloadSheetState extends State<SeasonDownloadSheet> {
  final Set<int> _selected = <int>{};
  final Map<int, String> _status = <int, String>{};
  DownloadStorageInfo? _storage;
  bool _wifiOnly = false;
  bool _running = false;
  bool _cancelRequested = false;
  bool _loading = true;
  String? _summary;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final service = context.read<DownloadService>();
    final storage = await service.storageInfo();
    if (!mounted) return;
    setState(() {
      _storage = storage;
      _wifiOnly = service.wifiOnly;
      for (final episode in widget.episodes) {
        final existing = service.downloadStateFor(
          widget.item,
          season: widget.season.seasonNumber,
          episode: episode.episodeNumber,
        );
        if (existing != null) {
          _status[episode.episodeNumber] = existing.isComplete
              ? 'Downloaded'
              : existing.isProcessing
                  ? 'Downloading'
                  : 'Failed';
        }
        if (existing == null || existing.isFailed) {
          _selected.add(episode.episodeNumber);
        }
      }
      _loading = false;
    });
  }

  Future<void> _startBatch() async {
    if (_running || _selected.isEmpty) return;
    final service = context.read<DownloadService>();
    setState(() {
      _running = true;
      _cancelRequested = false;
      _summary = null;
    });
    await service.setWifiOnly(_wifiOnly);
    var added = 0;
    var skipped = 0;
    var failed = 0;

    for (final episode in widget.episodes) {
      if (_cancelRequested) break;
      if (!_selected.contains(episode.episodeNumber)) continue;
      final existing = service.downloadStateFor(
        widget.item,
        season: widget.season.seasonNumber,
        episode: episode.episodeNumber,
      );
      if (existing != null && !existing.isFailed) {
        skipped++;
        if (mounted) {
          setState(() => _status[episode.episodeNumber] =
              existing.isComplete ? 'Already downloaded' : 'Already queued');
        }
        continue;
      }
      if (mounted) {
        setState(() => _status[episode.episodeNumber] = 'Finding a source…');
      }
      final resolution = await service.prepare(
        widget.item,
        season: widget.season.seasonNumber,
        episode: episode.episodeNumber,
      );
      if (!mounted) return;
      if (!resolution.isSuccess || resolution.stream == null) {
        failed++;
        setState(() => _status[episode.episodeNumber] =
            resolution.failure?.message ?? 'No source available');
        continue;
      }
      final sources = resolution.stream!.downloadSources;
      if (sources.isEmpty) {
        failed++;
        setState(() => _status[episode.episodeNumber] =
            'Streaming only · cannot download');
        continue;
      }
      final preferred = sources
          .where((source) => source.qualityValue > 0 && source.qualityValue <= 720)
          .toList()
        ..sort((a, b) => b.qualityValue.compareTo(a.qualityValue));
      final source = preferred.isNotEmpty ? preferred.first : sources.first;
      final captions = resolution.stream!.captions;
      final languages = <String>{};
      final preferredLanguages = service.preferredSubtitleLanguages;
      for (final caption in captions) {
        if (preferredLanguages.contains(caption.language)) {
          languages.add(caption.language);
        }
      }
      if (languages.isEmpty) {
        final defaults = captions.where((caption) => caption.isDefault);
        if (defaults.isNotEmpty) languages.add(defaults.first.language);
      }
      try {
        await service.startDownload(
          item: widget.item,
          season: widget.season.seasonNumber,
          episode: episode.episodeNumber,
          episodeTitle: episode.name,
          resolved: resolution.stream!,
          source: source,
          subtitleLanguages: languages,
          wifiOnly: _wifiOnly,
        );
        added++;
        if (mounted) {
          setState(() => _status[episode.episodeNumber] = 'Added to Downloads');
        }
      } catch (error) {
        failed++;
        if (mounted) {
          setState(() => _status[episode.episodeNumber] =
              error.toString().replaceFirst('Bad state: ', ''));
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _summary = _cancelRequested
          ? 'Batch stopped. $added added, $skipped already saved, $failed failed. '
              'Completed episodes were kept.'
          : '$added added · $skipped already saved · $failed failed';
    });
  }

  @override
  Widget build(BuildContext context) {
    final downloadedCount = widget.episodes
        .where((episode) => _status[episode.episodeNumber] == 'Downloaded')
        .length;
    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
        decoration: const BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: _loading
            ? const SizedBox(
                height: 220,
                child: Center(
                  child: CircularProgressIndicator(color: _accent),
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
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '${widget.item.title} · ${widget.season.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.episodes.length} episodes · $downloadedCount already downloaded',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: _running
                            ? null
                            : () => setState(() {
                                  _selected.addAll(
                                    widget.episodes
                                        .where((episode) =>
                                            _status[episode.episodeNumber] !=
                                            'Downloaded')
                                        .map((episode) => episode.episodeNumber),
                                  );
                                }),
                        child: const Text('Select all'),
                      ),
                      TextButton(
                        onPressed: _running
                            ? null
                            : () => setState(_selected.clear),
                        child: const Text('Clear'),
                      ),
                      const Spacer(),
                      Text(
                        '${_selected.length} selected',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: widget.episodes.length,
                      itemBuilder: (context, index) {
                        final episode = widget.episodes[index];
                        final status = _status[episode.episodeNumber];
                        final isDone = status == 'Downloaded';
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          activeColor: _accent,
                          checkColor: Colors.white,
                          value: _selected.contains(episode.episodeNumber),
                          onChanged: _running || isDone
                              ? null
                              : (checked) => setState(() {
                                    if (checked == true) {
                                      _selected.add(episode.episodeNumber);
                                    } else {
                                      _selected.remove(episode.episodeNumber);
                                    }
                                  }),
                          title: Text(
                            '${episode.episodeNumber}. ${episode.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                            ),
                          ),
                          subtitle: status == null
                              ? null
                              : Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isDone
                                        ? const Color(0xFF46D369)
                                        : Colors.white54,
                                    fontSize: 11.5,
                                  ),
                                ),
                        );
                      },
                    ),
                  ),
                  const Divider(color: Colors.white12),
                  Row(
                    children: [
                      const Icon(Icons.wifi, color: Colors.white54, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Wi-Fi only',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                      Switch(
                        value: _wifiOnly,
                        activeColor: _accent,
                        onChanged: _running
                            ? null
                            : (value) => setState(() => _wifiOnly = value),
                      ),
                    ],
                  ),
                  if (_storage != null && _storage!.isKnown)
                    Text(
                      '${_storage!.freeLabel} free on this device',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11.5,
                      ),
                    ),
                  const SizedBox(height: 6),
                  if (_summary != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _summary!,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const Text(
                    'Total size is confirmed as each episode resolves; sizes are '
                    'shown in Downloads once known.',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _running || _selected.isEmpty
                              ? null
                              : _startBatch,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: const Color(0xFF3A3A3A),
                            minimumSize: const Size(0, 46),
                          ),
                          icon: _running
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.download_rounded, size: 18),
                          label: Text(
                            _running
                                ? 'Starting batch…'
                                : 'Download ${_selected.length} episodes',
                          ),
                        ),
                      ),
                      if (_running) ...[
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: () =>
                              setState(() => _cancelRequested = true),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white30),
                            minimumSize: const Size(0, 46),
                          ),
                          child: const Text('Stop'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
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
