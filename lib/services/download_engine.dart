import 'dart:io';

import 'package:flutter/services.dart';

/// Storage figures reported by Android. All values are bytes.
class DownloadStorageInfo {
  final int totalBytes;
  final int freeBytes;
  final int appBytes;

  const DownloadStorageInfo({
    required this.totalBytes,
    required this.freeBytes,
    required this.appBytes,
  });

  bool get isKnown => freeBytes > 0;

  String get freeLabel => _format(freeBytes);
  String get totalLabel => _format(totalBytes);
  String get appLabel => _format(appBytes);

  static String _format(int bytes) {
    if (bytes <= 0) return 'Unknown';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

class DownloadEngineStatus {
  final int id;
  final String status;
  final int downloadedBytes;
  final int totalBytes;
  final int? failureReason;

  const DownloadEngineStatus({
    required this.id,
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    this.failureReason,
  });

  factory DownloadEngineStatus.fromMap(Map<dynamic, dynamic> map) {
    return DownloadEngineStatus(
      id: (map['id'] as num?)?.toInt() ?? 0,
      status: (map['status'] ?? 'unknown').toString(),
      downloadedBytes: (map['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      failureReason: (map['reason'] as num?)?.toInt(),
    );
  }
}

class DownloadEnqueueRequest {
  final String url;
  final String fileName;
  final String title;
  final String description;
  final Map<String, String> headers;
  final bool wifiOnly;

  const DownloadEnqueueRequest({
    required this.url,
    required this.fileName,
    required this.title,
    required this.description,
    required this.headers,
    required this.wifiOnly,
  });
}

/// Platform download bridge. Android's DownloadManager handles the transfer in
/// the background (including across process death); tests can substitute a
/// fake implementation.
abstract class DownloadEngine {
  bool get isSupported;
  bool get supportsPauseResume;

  Future<String> getDirectory();
  Future<Map<String, dynamic>> enqueue(DownloadEnqueueRequest request);
  Future<List<DownloadEngineStatus>> statuses(List<int> ids);
  Future<bool> cancel(int id);
  Future<DownloadStorageInfo?> storageInfo();
  Future<bool> requestNotificationPermission();
}

class UnsupportedDownloadEngine implements DownloadEngine {
  const UnsupportedDownloadEngine();

  @override
  bool get isSupported => false;

  @override
  bool get supportsPauseResume => false;

  @override
  Future<String> getDirectory() async => '';

  @override
  Future<Map<String, dynamic>> enqueue(DownloadEnqueueRequest request) async =>
      throw UnsupportedError('Downloads require Android.');

  @override
  Future<List<DownloadEngineStatus>> statuses(List<int> ids) async => const [];

  @override
  Future<bool> cancel(int id) async => false;

  @override
  Future<DownloadStorageInfo?> storageInfo() async => null;

  @override
  Future<bool> requestNotificationPermission() async => false;
}

/// Real bridge to `MainActivity`'s `flix.downloads` method channel.
class AndroidDownloadEngine implements DownloadEngine {
  static const MethodChannel _channel = MethodChannel('flix.downloads');

  const AndroidDownloadEngine();

  @override
  bool get isSupported => true;

  @override
  bool get supportsPauseResume => false;

  @override
  Future<String> getDirectory() async {
    final path = await _channel.invokeMethod<String>('getDirectory');
    return path ?? '';
  }

  @override
  Future<Map<String, dynamic>> enqueue(DownloadEnqueueRequest request) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'enqueue',
      {
        'url': request.url,
        'fileName': request.fileName,
        'title': request.title,
        'description': request.description,
        'headers': request.headers,
        'wifiOnly': request.wifiOnly,
      },
    );
    if (result == null) {
      throw StateError('Android did not return a download job.');
    }
    return result;
  }

  @override
  Future<List<DownloadEngineStatus>> statuses(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final response = await _channel.invokeListMethod<dynamic>(
      'getStatuses',
      {'ids': ids},
    );
    if (response == null) return const [];
    return response
        .whereType<Map>()
        .map(DownloadEngineStatus.fromMap)
        .where((status) => status.id > 0)
        .toList(growable: false);
  }

  @override
  Future<bool> cancel(int id) async {
    if (id <= 0) return false;
    final result = await _channel.invokeMethod<bool>('cancel', {'id': id});
    return result == true;
  }

  @override
  Future<DownloadStorageInfo?> storageInfo() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getStorageInfo',
    );
    if (result == null) return null;
    return DownloadStorageInfo(
      totalBytes: (result['totalBytes'] as num?)?.toInt() ?? 0,
      freeBytes: (result['freeBytes'] as num?)?.toInt() ?? 0,
      appBytes: (result['appBytes'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>(
        'requestNotificationPermission',
      );
      return granted == true;
    } catch (_) {
      return false;
    }
  }
}

DownloadEngine platformDownloadEngine() =>
    Platform.isAndroid ? const AndroidDownloadEngine() : const UnsupportedDownloadEngine();
