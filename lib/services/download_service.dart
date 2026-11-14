import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/api_constants.dart';
import '../models/caption_track.dart';
import '../models/media_item.dart';
import '../models/offline_download.dart';
import '../models/stream_source.dart';
import 'stream_resolver.dart';
import 'subtitle_service.dart';

class DownloadService extends ChangeNotifier {
  static const _storageKey = 'flix_offline_downloads_v1';
  static const MethodChannel _channel = MethodChannel('flix.downloads');

  final StreamResolver _resolver = StreamResolver();
  final List<OfflineDownload> _downloads = [];
  SharedPreferences? _preferences;
  Timer? _pollTimer;
  bool _initialized = false;
  bool _refreshing = false;
  String? _error;

  List<OfflineDownload> get downloads => List.unmodifiable(_downloads);
  List<OfflineDownload> get activeDownloads =>
      _downloads.where((job) => job.isActive).toList(growable: false);
  List<OfflineDownload> get completedDownloads =>
      _downloads.where((job) => job.isComplete).toList(growable: false);
  String? get error => _error;

  Future<void> init() async {
    if (_initialized) return;
    try {
      _preferences = await SharedPreferences.getInstance();
      final raw = _preferences?.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final value in decoded.whereType<Map>()) {
            try {
              final job =
                  OfflineDownload.fromJson(Map<String, dynamic>.from(value));
              if (job.filePath.isNotEmpty) _downloads.add(job);
            } catch (_) {
              // Ignore a damaged record without losing the rest of the library.
            }
          }
        }
      }
      _initialized = true;
      await refreshStatuses();
      _pollTimer =
          Timer.periodic(const Duration(seconds: 3), (_) => refreshStatuses());
      notifyListeners();
    } catch (error) {
      _error = 'Downloads could not be initialized: $error';
      _initialized = true;
      notifyListeners();
    }
  }

  Future<ResolvedMediaStream> prepare(MediaItem item,
      {int season = 0, int episode = 0}) async {
    await init();
    final result =
        await _resolver.resolve(item: item, season: season, episode: episode);
    if (result == null)
      throw StateError('This title is not available to download right now.');
    if (result.downloadSources.isEmpty) {
      throw StateError(
          'No downloadable video is available for this title. Try streaming instead.');
    }
    return result;
  }

  Future<OfflineDownload> startDownload({
    required MediaItem item,
    required int season,
    required int episode,
    required String episodeTitle,
    required ResolvedMediaStream resolved,
    required StreamSource source,
    required Set<String> subtitleIds,
    int profileIndex = 0,
  }) async {
    await init();
    if (!Platform.isAndroid)
      throw UnsupportedError(
          'In-app downloads are currently available on Android.');
    if (!source.isDownloadable)
      throw StateError('Only full-length MP4 files can be saved offline.');
    final selectedProfileIndex = profileIndex < 0 ||
            profileIndex >= ApiConstants.zarhostingMediaHeaderProfiles.length
        ? 0
        : profileIndex;

    final directory = await _channel.invokeMethod<String>('getDirectory');
    if (directory == null || directory.isEmpty)
      throw StateError('Flix could not open its private downloads folder.');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final episodePart = item.mediaType == 'tv' ? '_S${season}E$episode' : '';
    final fileBase =
        '${_safeName(item.title)}_${item.id}$episodePart_${source.qualityValue}p_$stamp';
    final videoName = '$fileBase.mp4';
    final localSubtitles = <OfflineSubtitle>[];

    for (final caption
        in resolved.captions.where((entry) => subtitleIds.contains(entry.id))) {
      try {
        final text = await SubtitleService.fetchText(caption);
        if (text.trim().isEmpty) continue;
        if (SubtitleService.parse(text).isEmpty) continue;
        final extension = _subtitleExtension(caption.url, text);
        final language = _safeName(caption.language.toLowerCase());
        final path =
            '$directory${Platform.pathSeparator}${fileBase}_$language.$extension';
        await File(path).writeAsString(text, flush: true);
        localSubtitles.add(OfflineSubtitle(
            language: caption.language,
            languageName: caption.languageName,
            path: path));
      } catch (_) {
        // A missing caption should not cancel the video transfer. The download
        // screen will still clearly show the video and any saved caption tracks.
      }
    }

    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('enqueue', {
        'url': source.url,
        'fileName': videoName,
        'title': item.mediaType == 'tv'
            ? '${item.title} · S$season:E$episode'
            : item.title,
        'description': 'Saved privately in Flix · ${source.resolution}',
        'headers':
            ApiConstants.zarhostingMediaHeaderProfiles[selectedProfileIndex],
      });
      if (result == null ||
          result['id'] == null ||
          result['filePath'] == null) {
        throw StateError('Android did not return a download job.');
      }

      final job = OfflineDownload(
        key: '${result['id']}-$stamp',
        nativeId: (result['id'] as num).toInt(),
        item: item,
        season: season,
        episode: episode,
        episodeTitle: episodeTitle,
        resolution: source.resolution,
        filePath: result['filePath'].toString(),
        subtitles: localSubtitles,
        status: 'pending',
        downloadedBytes: 0,
        totalBytes: source.sizeBytes,
        createdAt: DateTime.now(),
        profileIndex: selectedProfileIndex,
      );
      _downloads.insert(0, job);
      _error = null;
      await _persist();
      notifyListeners();
      return job;
    } catch (_) {
      for (final subtitle in localSubtitles) {
        try {
          final file = File(subtitle.path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> retry(OfflineDownload job) async {
    await init();
    final previousIndex =
        _downloads.indexWhere((entry) => entry.key == job.key);
    final nextProfile = (job.profileIndex + 1)
        .clamp(0, ApiConstants.zarhostingMediaHeaderProfiles.length - 1)
        .toInt();
    try {
      await _channel.invokeMethod<bool>('cancel', {'id': job.nativeId});
      final fresh = await _resolver.resolve(
        item: job.item,
        season: job.season,
        episode: job.episode,
        forceRefresh: true,
      );
      if (fresh == null || fresh.downloadSources.isEmpty) {
        throw StateError('A fresh offline copy is not available right now.');
      }
      final source = fresh.downloadSources.firstWhere(
        (candidate) => candidate.resolution == job.resolution,
        orElse: () => fresh.downloadSources.first,
      );
      for (final subtitle in job.subtitles) {
        try {
          final file = File(subtitle.path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      if (previousIndex >= 0) _downloads.removeAt(previousIndex);
      await startDownload(
        item: job.item,
        season: job.season,
        episode: job.episode,
        episodeTitle: job.episodeTitle,
        resolved: fresh,
        source: source,
        subtitleIds: fresh.captions.map((caption) => caption.id).toSet(),
        profileIndex: nextProfile,
      );
    } catch (error) {
      _error = 'Could not restart this download: $error';
      if (previousIndex >= 0 &&
          !_downloads.any((entry) => entry.key == job.key)) {
        _downloads.insert(previousIndex.clamp(0, _downloads.length).toInt(),
            job.copyWith(status: 'failed'));
      }
      await _persist();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> cancel(OfflineDownload job) async {
    await _channel.invokeMethod<bool>('cancel', {'id': job.nativeId});
    final index = _downloads.indexWhere((entry) => entry.key == job.key);
    if (index >= 0) {
      _downloads[index] = job.copyWith(status: 'cancelled');
      await _persist();
      notifyListeners();
    }
  }

  Future<void> delete(OfflineDownload job) async {
    if (Platform.isAndroid)
      await _channel.invokeMethod<bool>('cancel', {'id': job.nativeId});
    for (final path in [
      job.filePath,
      ...job.subtitles.map((caption) => caption.path)
    ]) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    _downloads.removeWhere((entry) => entry.key == job.key);
    await _persist();
    notifyListeners();
  }

  Future<void> refreshStatuses() async {
    if (!_initialized ||
        _refreshing ||
        _downloads.isEmpty ||
        !Platform.isAndroid) return;
    _refreshing = true;
    try {
      final response = await _channel.invokeListMethod<dynamic>('getStatuses', {
        'ids': _downloads.map((job) => job.nativeId).toList(),
      });
      if (response == null) return;
      var changed = false;
      for (final value in response.whereType<Map>()) {
        final id = (value['id'] as num?)?.toInt();
        if (id == null) continue;
        final index = _downloads.indexWhere((job) => job.nativeId == id);
        if (index < 0) continue;
        final current = _downloads[index];
        final nextStatus = (value['status'] ?? current.status).toString();
        final updated = current.copyWith(
          status: nextStatus,
          downloadedBytes: (value['downloadedBytes'] as num?)?.toInt() ??
              current.downloadedBytes,
          totalBytes:
              (value['totalBytes'] as num?)?.toInt() ?? current.totalBytes,
          failureReason: (value['reason'] as num?)?.toInt(),
        );
        if (updated.status != current.status ||
            updated.downloadedBytes != current.downloadedBytes ||
            updated.totalBytes != current.totalBytes ||
            updated.failureReason != current.failureReason) {
          _downloads[index] = updated;
          changed = true;
        }
      }
      if (changed) {
        await _persist();
        notifyListeners();
      }
    } catch (error) {
      _error = 'Download status could not be refreshed: $error';
      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _persist() async {
    try {
      _preferences ??= await SharedPreferences.getInstance();
      await _preferences!.setString(_storageKey,
          jsonEncode(_downloads.map((job) => job.toJson()).toList()));
    } catch (error) {
      _error = 'Download list could not be saved: $error';
    }
  }

  static String _safeName(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty
        ? 'title'
        : cleaned.substring(0, cleaned.length.clamp(0, 48).toInt());
  }

  static String _subtitleExtension(String url, String text) {
    final lower = url.toLowerCase();
    if (lower.contains('.vtt') || text.trimLeft().startsWith('WEBVTT'))
      return 'vtt';
    return 'srt';
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
