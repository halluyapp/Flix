import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/api_constants.dart';
import '../models/caption_load.dart';
import '../models/caption_track.dart';
import '../models/media_item.dart';
import '../models/provider_match.dart';
import '../models/offline_download.dart';
import '../models/stream_source.dart';
import 'diagnostics_service.dart';
import 'download_engine.dart';
import 'media_probe.dart';
import 'download_validation.dart';
import 'stream_resolver.dart';
import 'subtitle_service.dart';

/// Thrown when Flix already has this exact media + quality.
class DownloadConflictException implements Exception {
  final OfflineDownload existing;

  const DownloadConflictException(this.existing);

  @override
  String toString() => existing.isComplete
      ? 'This quality is already downloaded.'
      : 'This quality is already queued.';
}

/// The provider's CDN refused every link for a title (rate limit, region or an
/// expired signature). The message is shown to the viewer as-is.
class MediaUnavailableException implements Exception {
  final int statusCode;

  const MediaUnavailableException(this.statusCode);

  @override
  String toString() {
    if (statusCode == 429) {
      return 'The provider is rate-limiting this title (HTTP 429). Wait a '
          'minute and try again, or choose another quality.';
    }
    if (statusCode > 0) {
      return 'The provider refused this file (HTTP $statusCode). Try another '
          'quality.';
    }
    return 'The provider did not return a playable file for this title.';
  }
}

/// Manages the offline library.
///
/// Android's DownloadManager performs the transfer in the background and
/// survives process death; this service owns the queue metadata, real progress,
/// integrity verification, paired subtitle files and honest recovery states.
/// It never reports a download as ready until the local file has been verified.
class DownloadService extends ChangeNotifier {
  DownloadService({
    StreamResolver? resolver,
    DownloadEngine? engine,
    MediaProbe? probe,
  })  : _resolver = resolver ?? StreamResolver(),
        _engine = engine ?? platformDownloadEngine(),
        _probe = probe ?? MediaProbe();

  static const String _queueKey = 'flix_offline_downloads_v2';
  static const String _wifiKey = 'flix_downloads_wifi_only';
  static const String _subtitleLanguageKey = 'flix_downloads_subtitle_languages';

  final StreamResolver _resolver;
  final DownloadEngine _engine;
  final MediaProbe _probe;
  final List<OfflineDownload> _downloads = [];
  SharedPreferences? _preferences;
  Timer? _pollTimer;
  bool _initialized = false;
  bool _refreshing = false;
  String? _error;
  bool _wifiOnly = false;
  List<String> _preferredSubtitleLanguages = const [];
  bool _disposed = false;

  /// Background subtitle pass for the most recent download. Tests await it;
  /// the app never does, so a subtitle pass cannot delay a video.
  @visibleForTesting
  Future<void>? pendingSubtitleWork;
  Future<void> _persistChain = Future.value();

  List<OfflineDownload> get downloads => List.unmodifiable(_downloads);

  List<OfflineDownload> get activeDownloads =>
      _downloads.where((job) => job.isProcessing).toList(growable: false);

  List<OfflineDownload> get completedDownloads =>
      _downloads.where((job) => job.isComplete).toList(growable: false);

  List<OfflineDownload> get failedDownloads =>
      _downloads.where((job) => job.isFailed).toList(growable: false);

  String? get error => _error;
  bool get wifiOnly => _wifiOnly;
  bool get supportsDownloads => _engine.isSupported;
  bool get supportsPauseResume => _engine.supportsPauseResume;
  List<String> get preferredSubtitleLanguages =>
      List.unmodifiable(_preferredSubtitleLanguages);

  int get usedBytes {
    var total = 0;
    for (final job in _downloads) {
      if (job.isComplete) total += job.sizeOnDisk;
    }
    return total;
  }

  Future<void>? _initializing;

  Future<void> init() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    _initialized = true;
    try {
      _preferences = await SharedPreferences.getInstance();
      _wifiOnly = _preferences?.getBool(_wifiKey) ?? false;
      _preferredSubtitleLanguages =
          _preferences?.getStringList(_subtitleLanguageKey) ?? const [];
      final raw = _preferences?.getString(_queueKey) ??
          _preferences?.getString('flix_offline_downloads_v1');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final value in decoded.whereType<Map>()) {
            try {
              final job = OfflineDownload.fromJson(
                Map<String, dynamic>.from(value),
              );
              if (job.filePath.isNotEmpty) _downloads.add(job);
            } catch (_) {
              // Ignore one damaged record without losing the library.
            }
          }
        }
      }
      await refreshStatuses();
      _restartPolling();
      notifyListeners();
    } catch (error) {
      _error = 'Downloads could not be initialized: ${error.runtimeType}';
      DiagnosticsService.instance.record(
        scope: 'downloads',
        operation: 'init',
        error: error,
      );
      notifyListeners();
    }
  }

  Future<PlaybackResolution> prepare(
    MediaItem item, {
    int season = 0,
    int episode = 0,
    bool forceRefresh = false,
  }) async {
    await init();
    return _resolver.resolve(
      item: item,
      season: season,
      episode: episode,
      forceRefresh: forceRefresh,
    );
  }

  OfflineDownload? findDownload(
    MediaItem item, {
    int season = 0,
    int episode = 0,
    int? qualityValue,
    bool includeFailures = false,
  }) {
    for (final job in _downloads) {
      if (job.item.id != item.id || job.item.mediaType != item.mediaType) {
        continue;
      }
      if (item.mediaType == 'tv' &&
          (job.season != season || job.episode != episode)) {
        continue;
      }
      if (qualityValue != null && job.qualityValue != qualityValue) continue;
      if (!includeFailures && job.isFailed) continue;
      return job;
    }
    return null;
  }

  /// Best state to show next to a movie/episode row.
  OfflineDownload? downloadStateFor(
    MediaItem item, {
    int season = 0,
    int episode = 0,
  }) {
    final matches = _downloads
        .where((job) =>
            job.item.id == item.id &&
            job.item.mediaType == item.mediaType &&
            (item.mediaType != 'tv' ||
                (job.season == season && job.episode == episode)))
        .toList();
    if (matches.isEmpty) return null;
    for (final job in matches) {
      if (job.isComplete) return job;
    }
    for (final job in matches) {
      if (job.isProcessing) return job;
    }
    return matches.first;
  }

  Future<OfflineDownload> startDownload({
    required MediaItem item,
    required int season,
    required int episode,
    required String episodeTitle,
    required ResolvedMediaStream resolved,
    required StreamSource source,
    required Set<String> subtitleLanguages,
    int profileIndex = 0,
    bool? wifiOnly,
  }) async {
    await init();
    if (!_engine.isSupported) {
      throw StateError(
        'Offline downloads are available in the Android app. This build can '
        'stream but cannot save files.',
      );
    }
    if (!source.isDownloadable) {
      throw StateError(
        source.downloadUnsupportedReason ??
            'This source cannot be saved as one offline file.',
      );
    }

    final isEpisode = item.mediaType == 'tv';
    final effectiveSeason = isEpisode ? season : 0;
    final effectiveEpisode = isEpisode ? episode : 0;

    // Never queue a link the provider is refusing. A signed URL can be
    // rate-limited (HTTP 429), region-blocked or already expired; checking the
    // first bytes first lets Flix fall back to another quality, or say what
    // happened instead of leaving a dead download in the library.
    var chosen = source;
    var effective = resolved;
    var probe = await _probe.check(chosen);
    if (probe.blocked) {
      for (final candidate in resolved.downloadSources) {
        if (candidate.url == chosen.url) continue;
        final alternative = await _probe.check(candidate);
        if (!alternative.blocked) {
          chosen = candidate;
          probe = alternative;
          break;
        }
      }
    }
    if (probe.blocked) {
      // Signed links expire and the CDN rate-limits bursts: give it a moment,
      // then ask the provider for a new link before failing this download.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      _resolver.invalidate(
        item: item,
        season: effectiveSeason,
        episode: effectiveEpisode,
      );
      final fresh = await _resolver.resolve(
        item: item,
        season: effectiveSeason,
        episode: effectiveEpisode,
        forceRefresh: true,
      );
      if (fresh.isSuccess) {
        effective = fresh.stream!;
        for (final candidate in effective.downloadSources) {
          final again = await _probe.check(candidate);
          if (!again.blocked) {
            chosen = candidate;
            probe = again;
            break;
          }
        }
      }
    }
    if (probe.blocked) {
      throw MediaUnavailableException(probe.statusCode);
    }

    final conflict = findDownload(
      item,
      season: effectiveSeason,
      episode: effectiveEpisode,
      qualityValue: chosen.qualityValue,
    );
    if (conflict != null) throw DownloadConflictException(conflict);

    final directory = await _engine.getDirectory();
    if (directory.isEmpty) {
      throw StateError('Flix could not open its private downloads folder.');
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = DownloadValidation.videoFileName(
      title: item.title,
      tmdbId: item.id,
      isEpisode: isEpisode,
      season: effectiveSeason,
      episode: effectiveEpisode,
      qualityValue: chosen.qualityValue,
      stamp: stamp,
    );
    final videoPath = '$directory${Platform.pathSeparator}$fileName';

    await _engine.requestNotificationPermission();
    final result = await _engine.enqueue(
      DownloadEnqueueRequest(
        url: chosen.url,
        fileName: fileName,
        title: isEpisode
            ? '${item.title} · S$effectiveSeason:E$effectiveEpisode'
            : item.title,
        description: 'Saved in Flix · ${chosen.resolution}',
        headers: <String, String>{
          ...ApiConstants.zarhostingMediaHeaders,
          ...chosen.headers,
        },
        wifiOnly: wifiOnly ?? _wifiOnly,
      ),
    );
    final nativeId = (result['id'] as num?)?.toInt() ?? 0;
    if (nativeId <= 0) {
      throw StateError('Android did not start this download.');
    }
    final returnedPath = (result['filePath'] ?? videoPath).toString();

    final job = OfflineDownload(
      key: '$nativeId-$stamp',
      nativeId: nativeId,
      item: item,
      season: effectiveSeason,
      episode: effectiveEpisode,
      episodeTitle: episodeTitle,
      resolution: chosen.resolution,
      qualityValue: chosen.qualityValue,
      filePath: returnedPath,
      subtitles: const [],
      subtitleLanguages: subtitleLanguages.toList()..sort(),
      status: 'pending',
      downloadedBytes: 0,
      totalBytes: chosen.sizeBytes,
      expectedBytes: chosen.sizeBytes,
      createdAt: DateTime.now(),
      profileIndex: profileIndex,
      verified: false,
      format: chosen.format,
    );

    // A failed record for the same media + quality is superseded, never a
    // verified file: the new transfer uses its own unique file name.
    _downloads.removeWhere(
      (entry) =>
          entry.isFailed && entry.downloadIdentity == job.downloadIdentity,
    );
    _downloads.insert(0, job);
    _error = null;
    await _persist();
    _restartPolling();
    notifyListeners();
    if (subtitleLanguages.isNotEmpty) {
      // Subtitles are saved after the video is queued; they never delay it.
      final pass = _attachSubtitles(
        job: job,
        match: effective.match,
        languages: subtitleLanguages.toSet(),
        directory: directory,
        // The engine's own path, so subtitle names follow the real file.
        videoPath: returnedPath,
        initialLoad: effective.captionLoad,
      );
      pendingSubtitleWork = pass;
      unawaited(pass);
    }
    return job;
  }

  /// Re-resolves and restarts a failed download. A verified copy is never
  /// replaced or deleted.
  Future<void> retry(OfflineDownload job) async {
    await init();
    if (job.isComplete) return;

    final resolution = await _resolver.resolve(
      item: job.item,
      season: job.season,
      episode: job.episode,
      forceRefresh: true,
    );
    if (!resolution.isSuccess) {
      throw StateError(
        resolution.failure?.message ?? 'A fresh offline copy is not available.',
      );
    }
    final stream = resolution.stream!;
    final candidates = stream.downloadSources;
    if (candidates.isEmpty) {
      throw StateError(
        stream.streamingOnlySources.isNotEmpty
            ? 'Only segmented (HLS/DASH) sources are available right now. '
                'Flix cannot save those as one offline file.'
            : 'No downloadable MP4 is available for this title right now.',
      );
    }
    final source = candidates.firstWhere(
      (candidate) => candidate.qualityValue == job.qualityValue,
      orElse: () => candidates.first,
    );

    final languages = job.subtitleLanguages.isNotEmpty
        ? job.subtitleLanguages.toSet()
        : _preferredSubtitleLanguages.toSet();
    _downloads.removeWhere((entry) => entry.key == job.key);
    await _persist();
    await startDownload(
      item: job.item,
      season: job.season,
      episode: job.episode,
      episodeTitle: job.episodeTitle,
      resolved: stream,
      source: source,
      subtitleLanguages: languages,
      profileIndex: job.profileIndex,
    );
  }

  Future<void> cancel(OfflineDownload job) async {
    await init();
    if (job.nativeId > 0) {
      try {
        await _engine.cancel(job.nativeId);
      } catch (_) {
        // The record is still updated honestly below.
      }
    }
    final index = _downloads.indexWhere((entry) => entry.key == job.key);
    if (index >= 0) {
      _downloads[index] = job.copyWith(
        status: 'cancelled',
        failureMessage: 'Cancelled. Restart it if you want this copy again.',
      );
      await _persist();
      notifyListeners();
    }
  }

  /// Removes one download and its files. Only files inside Flix's managed
  /// download directory are ever touched.
  Future<void> delete(OfflineDownload job) async {
    await init();
    if (job.isProcessing && job.nativeId > 0) {
      try {
        await _engine.cancel(job.nativeId);
      } catch (_) {}
    }
    final directory = await _engine.getDirectory();
    if (directory.isNotEmpty) {
      for (final path in [
        job.filePath,
        ...job.subtitles.map((subtitle) => subtitle.path),
      ]) {
        if (!DownloadValidation.isWithinDirectory(path, directory)) continue;
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    _downloads.removeWhere((entry) => entry.key == job.key);
    await _persist();
    notifyListeners();
  }

  Future<void> deleteAll() async {
    await init();
    final snapshot = List<OfflineDownload>.from(_downloads);
    for (final job in snapshot) {
      await delete(job);
    }
  }

  Future<DownloadStorageInfo?> storageInfo() async {
    try {
      return await _engine.storageInfo();
    } catch (_) {
      return null;
    }
  }

  Future<void> setWifiOnly(bool value) async {
    _wifiOnly = value;
    try {
      _preferences ??= await SharedPreferences.getInstance();
      await _preferences?.setBool(_wifiKey, value);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setPreferredSubtitleLanguages(List<String> languages) async {
    _preferredSubtitleLanguages = List.unmodifiable(languages);
    try {
      _preferences ??= await SharedPreferences.getInstance();
      await _preferences?.setStringList(
        _subtitleLanguageKey,
        _preferredSubtitleLanguages,
      );
    } catch (_) {}
    notifyListeners();
  }

  Future<void> refreshStatuses() async {
    if (!_initialized || _refreshing || !_engine.isSupported) return;
    final pending = _downloads
        .where((job) =>
            job.isProcessing || (job.status == 'completed' && !job.verified))
        .toList(growable: false);
    if (pending.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    _refreshing = true;
    try {
      final ids = pending
          .map((job) => job.nativeId)
          .where((id) => id > 0)
          .toSet()
          .toList(growable: false);
      final statuses = ids.isEmpty
          ? const <DownloadEngineStatus>[]
          : await _engine.statuses(ids);
      final byId = {for (final status in statuses) status.id: status};
      var changed = false;

      for (var index = 0; index < _downloads.length; index++) {
        final job = _downloads[index];
        if (!job.isProcessing &&
            !(job.status == 'completed' && !job.verified)) {
          continue;
        }
        if (job.nativeId <= 0) {
          _downloads[index] = job.copyWith(
            status: 'failed',
            failureMessage:
                job.failureMessage ?? 'Android could not start this download.',
          );
          changed = true;
          continue;
        }
        final status = byId[job.nativeId];
        if (status == null) {
          _downloads[index] = job.copyWith(
            status: 'failed',
            failureMessage:
                'The download was interrupted before it finished. Restart it '
                'to try again.',
          );
          changed = true;
          continue;
        }

        OfflineDownload next;
        if (status.status == 'completed') {
          next = await _verify(
            job.copyWith(
              downloadedBytes: status.downloadedBytes,
              totalBytes: status.totalBytes > 0
                  ? status.totalBytes
                  : job.totalBytes,
            ),
          );
        } else if (status.status == 'failed') {
          next = job.copyWith(
            status: 'failed',
            downloadedBytes: status.downloadedBytes,
            totalBytes: status.totalBytes > 0
                ? status.totalBytes
                : job.totalBytes,
            failureReason: status.failureReason,
            failureMessage:
                DownloadValidation.failureMessage(status.failureReason),
          );
        } else {
          next = job.copyWith(
            status: status.status,
            downloadedBytes: status.downloadedBytes,
            totalBytes: status.totalBytes > 0
                ? status.totalBytes
                : job.totalBytes,
            clearFailure: status.status == 'running',
          );
        }

        if (next.status != job.status ||
            next.downloadedBytes != job.downloadedBytes ||
            next.totalBytes != job.totalBytes ||
            next.verified != job.verified ||
            next.failureMessage != job.failureMessage) {
          _downloads[index] = next;
          changed = true;
        }
      }

      if (changed) {
        _error = null;
        await _persist();
        notifyListeners();
      }
    } catch (error) {
      _error = 'Download status could not be refreshed: ${error.runtimeType}';
      notifyListeners();
    } finally {
      _refreshing = false;
      _restartPolling();
    }
  }

  Future<OfflineDownload> _verify(OfflineDownload job) async {
    final file = File(job.filePath);
    if (!await file.exists()) {
      return job.copyWith(
        status: 'corrupt',
        verified: false,
        failureMessage:
            'The video file is missing from this device. Download it again.',
      );
    }
    final length = await file.length();
    if (length <= 0) {
      return job.copyWith(
        status: 'corrupt',
        verified: false,
        failureMessage:
            'The downloaded file is empty. Download it again to fix this.',
      );
    }
    if (job.expectedBytes > 0 &&
        length < (job.expectedBytes * 0.97).round()) {
      return job.copyWith(
        status: 'corrupt',
        verified: false,
        downloadedBytes: length,
        failureMessage:
            'The download ended early ($length of ${job.expectedBytes} bytes). '
            'Restart it to get the full file.',
      );
    }

    try {
      final handle = await file.open();
      try {
        final header = await handle.read(512);
        if (header.isNotEmpty &&
            DownloadValidation.looksLikeMarkup(
              utf8.decode(header, allowMalformed: true),
            )) {
          return job.copyWith(
            status: 'corrupt',
            verified: false,
            failureMessage:
                'The provider returned a web page instead of a video file. '
                'This source cannot be downloaded right now.',
          );
        }
      } finally {
        await handle.close();
      }
    } catch (_) {
      // A read failure is not proof of corruption; size checks already ran.
    }

    return job.copyWith(
      status: 'completed',
      verified: true,
      downloadedBytes: length,
      clearFailure: true,
      failureReason: null,
    );
  }

  /// Saves the selected subtitles for an already-queued video. Runs in the
  /// background so a slow or failing subtitle host never delays or cancels
  /// the video transfer. Every language ends up either saved or with a reason.
  Future<void> _attachSubtitles({
    required OfflineDownload job,
    required ProviderMatch match,
    required Set<String> languages,
    required String directory,
    required String videoPath,
    CaptionLoad? initialLoad,
  }) async {
    try {
      var load = initialLoad;
      if (load == null ||
          load.status == CaptionLoadStatus.pending ||
          load.status == CaptionLoadStatus.failed) {
        load = await _resolver.refreshCaptions(
          item: job.item,
          providerMatch: match,
          season: job.season,
          episode: job.episode,
        );
      }
      final result = await _saveSelected(
        load: load,
        languages: languages,
        directory: directory,
        videoPath: videoPath,
      );
      final updated = await _mutateJob(
        job.key,
        (current) => current.copyWith(
          subtitles: _mergeSubtitles(current.subtitles, result.saved),
          subtitleIssues: result.issues,
        ),
      );
      if (updated == null) {
        // The download was deleted while its subtitles were being saved.
        await _deleteSubtitleFiles(result.saved, directory);
        return;
      }
      DiagnosticsService.instance.record(
        scope: 'downloads',
        operation: 'subtitle_pairing',
        data: {
          'selected': languages.length,
          'saved': result.saved.length,
          'missing': result.issues.keys.join(','),
        },
      );
    } catch (error) {
      DiagnosticsService.instance.record(
        scope: 'downloads',
        operation: 'subtitle_pairing',
        error: error,
      );
      await _mutateJob(
        job.key,
        (current) => current.copyWith(
          subtitleIssues: {
            for (final language in languages)
              language: 'Subtitles could not be saved. Retry subtitles.',
          },
        ),
      );
    }
  }

  Future<_SubtitleSaveResult> _saveSelected({
    required CaptionLoad load,
    required Set<String> languages,
    required String directory,
    required String videoPath,
  }) async {
    if (!load.isLoaded) {
      return _SubtitleSaveResult(
        saved: const [],
        issues: {
          for (final language in languages) language: load.userMessage,
        },
      );
    }
    final candidates = load.tracks
        .where((track) => languages.contains(track.language))
        .toList(growable: false);
    final write = await _saveSubtitles(
      tracks: candidates,
      directory: directory,
      videoPath: videoPath,
    );
    final savedLanguages = write.saved.map((entry) => entry.language).toSet();
    final issues = <String, String>{};
    for (final language in languages) {
      if (savedLanguages.contains(language)) continue;
      issues[language] = write.failures[language] ??
          (candidates.any((track) => track.language == language)
              ? 'Subtitles could not be saved.'
              : 'The provider does not list this language for this episode.');
    }
    return _SubtitleSaveResult(saved: write.saved, issues: issues);
  }

  /// Writes each track to its own file, named after the video so the pair
  /// stays deterministic. Tracks that share a language get a numbered tag.
  Future<_SubtitleWriteResult> _saveSubtitles({
    required List<CaptionTrack> tracks,
    required String directory,
    required String videoPath,
  }) async {
    final saved = <OfflineSubtitle>[];
    final failures = <String, String>{};
    final tagCounts = <String, int>{};
    for (final track in tracks) {
      final base = DownloadValidation.safeName(track.language, maxLength: 12);
      final count = (tagCounts[base] ?? 0) + 1;
      tagCounts[base] = count;
      final tag = count == 1 ? base : '${base}_$count';
      try {
        final file = await SubtitleService.fetchValidated(track);
        final path = '$directory${Platform.pathSeparator}'
            '${DownloadValidation.subtitleFileName(videoPath: videoPath, language: tag, extension: file.extension)}';
        await File(path).writeAsString(file.text, flush: true);
        saved.add(
          OfflineSubtitle(
            language: track.language,
            languageName: track.languageName,
            path: path,
            sizeBytes: file.sizeBytes,
          ),
        );
      } on SubtitleException catch (error) {
        failures[track.language] = error.message;
      } catch (_) {
        failures[track.language] =
            'The subtitle could not be saved to this device.';
      }
    }
    return _SubtitleWriteResult(saved: saved, failures: failures);
  }

  /// Keeps one entry per file. A re-saved subtitle replaces its old entry.
  static List<OfflineSubtitle> _mergeSubtitles(
    List<OfflineSubtitle> existing,
    List<OfflineSubtitle> added,
  ) {
    final byPath = <String, OfflineSubtitle>{
      for (final subtitle in existing) subtitle.path: subtitle,
    };
    for (final subtitle in added) {
      byPath[subtitle.path] = subtitle;
    }
    return byPath.values
        .where((subtitle) => subtitle.isUsable)
        .toList(growable: false);
  }

  OfflineDownload? _findByKey(String key) {
    for (final entry in _downloads) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  /// Applies [change] to the stored record and persists it. Returns null when
  /// the download no longer exists.
  Future<OfflineDownload?> _mutateJob(
    String key,
    OfflineDownload Function(OfflineDownload job) change,
  ) async {
    final index = _downloads.indexWhere((entry) => entry.key == key);
    if (index < 0) return null;
    final updated = change(_downloads[index]);
    _downloads[index] = updated;
    await _persist();
    if (!_disposed) notifyListeners();
    return updated;
  }

  /// Saves only the subtitle languages still missing for a downloaded video.
  /// Saved files and the video are left untouched, and no stream is
  /// re-resolved: only the subtitle list is fetched again.
  Future<SubtitleRetryReport> retrySubtitles(OfflineDownload job) async {
    await init();
    final current = _findByKey(job.key);
    if (current == null) {
      throw StateError('This download is no longer in your library.');
    }
    final directory = await _engine.getDirectory();
    if (directory.isEmpty) {
      throw StateError('Flix could not open its private downloads folder.');
    }

    // Only the languages chosen for this download are ever fetched.
    final wanted = current.subtitleLanguages.toSet();
    final saved = current.subtitles
        .where((subtitle) => subtitle.isUsable)
        .map((subtitle) => subtitle.language)
        .toSet();
    final missing =
        wanted.where((language) => !saved.contains(language)).toSet();
    if (missing.isEmpty) {
      return SubtitleRetryReport(
        job: current,
        saved: const [],
        failed: const {},
        unavailable: const [],
      );
    }

    final load = await _resolver.refreshCaptions(
      item: current.item,
      season: current.season,
      episode: current.episode,
      forceRefresh: true,
    );
    if (!load.isLoaded) {
      final reason = load.userMessage;
      final updated = await _mutateJob(
        current.key,
        (entry) => entry.copyWith(
          subtitleIssues: {
            ...entry.subtitleIssues,
            for (final language in missing) language: reason,
          },
        ),
      );
      return SubtitleRetryReport(
        job: updated ?? current,
        saved: const [],
        failed: {for (final language in missing) language: reason},
        unavailable: const [],
      );
    }

    final targets = load.tracks
        .where((track) => missing.contains(track.language))
        .toList(growable: false);
    final unavailable = missing
        .where((language) =>
            !load.tracks.any((track) => track.language == language))
        .toList(growable: false);

    final write = await _saveSubtitles(
      tracks: targets,
      directory: directory,
      videoPath: current.filePath,
    );
    final savedLanguages =
        write.saved.map((subtitle) => subtitle.language).toSet();
    final failed = <String, String>{
      for (final entry in write.failures.entries)
        if (!savedLanguages.contains(entry.key)) entry.key: entry.value,
    };
    final issues = <String, String>{
      for (final language in unavailable)
        language: 'The provider does not list this language for this episode.',
      ...failed,
    };

    final updated = await _mutateJob(
      current.key,
      (entry) => entry.copyWith(
        subtitles: _mergeSubtitles(entry.subtitles, write.saved),
        subtitleIssues: issues,
      ),
    );
    if (updated == null) {
      await _deleteSubtitleFiles(write.saved, directory);
      throw StateError('This download was removed while subtitles were saved.');
    }
    return SubtitleRetryReport(
      job: updated,
      saved: savedLanguages.toList()..sort(),
      failed: failed,
      unavailable: unavailable,
    );
  }

  Future<void> _deleteSubtitleFiles(
    List<OfflineSubtitle> subtitles,
    String directory,
  ) async {
    for (final subtitle in subtitles) {
      if (!DownloadValidation.isWithinDirectory(subtitle.path, directory)) {
        continue;
      }
      try {
        final file = File(subtitle.path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  void _restartPolling() {
    if (!_engine.isSupported) return;
    final hasActive = _downloads.any(
      (job) =>
          job.isProcessing || (job.status == 'completed' && !job.verified),
    );
    if (!hasActive) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer ??= Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) => refreshStatuses(),
    );
  }

  /// Persists snapshots in order so an older asynchronous write can never
  /// overwrite a newer one.
  Future<void> _persist() {
    final payload = jsonEncode(
      _downloads.map((job) => job.toJson()).toList(growable: false),
    );
    _persistChain = _persistChain.then((_) async {
      try {
        _preferences ??= await SharedPreferences.getInstance();
        await _preferences?.setString(_queueKey, payload);
      } catch (error) {
        _error = 'Download list could not be saved: ${error.runtimeType}';
      }
    });
    return _persistChain;
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _probe.dispose();
    super.dispose();
  }
}

/// Summary of a subtitle retry, shown to the viewer.
class SubtitleRetryReport {
  final OfflineDownload job;
  final List<String> saved;
  final Map<String, String> failed;
  final List<String> unavailable;

  const SubtitleRetryReport({
    required this.job,
    required this.saved,
    required this.failed,
    required this.unavailable,
  });

  /// Short, user-facing summary of what changed.
  String get summary {
    final parts = <String>[];
    if (saved.isNotEmpty) parts.add('Saved ${saved.join(', ')}.');
    if (failed.isNotEmpty) {
      final reasons = failed.values.toSet().join(' ');
      parts.add('Still missing ${failed.keys.join(', ')}. $reasons');
    }
    if (unavailable.isNotEmpty) {
      parts.add('Not offered for this episode: ${unavailable.join(', ')}.');
    }
    return parts.isEmpty
        ? 'All selected subtitles are already saved.'
        : parts.join(' ');
  }
}

class _SubtitleWriteResult {
  final List<OfflineSubtitle> saved;
  final Map<String, String> failures;

  const _SubtitleWriteResult({required this.saved, required this.failures});
}

class _SubtitleSaveResult {
  final List<OfflineSubtitle> saved;
  final Map<String, String> issues;

  const _SubtitleSaveResult({required this.saved, required this.issues});
}
