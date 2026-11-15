import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import '../core/provider/provider_failures.dart';

/// Small, dependency-free rolling diagnostic log.
///
/// Nothing here is sent anywhere automatically. Entries are sanitized (URLs
/// lose their query strings, tokens and e-mail addresses are redacted) and the
/// log can be exported by the viewer for debugging.
class DiagnosticsService {
  DiagnosticsService._();

  static final DiagnosticsService instance = DiagnosticsService._();

  static const int maxEntries = 400;
  static const String _fileName = 'flix_diagnostics.txt';

  final List<String> _entries = <String>[];
  bool _installed = false;

  bool get isInstalled => _installed;

  /// Installs framework and platform error capture exactly once.
  void install() {
    if (_installed) return;
    _installed = true;

    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      record(
        scope: 'flutter',
        operation: 'framework_error',
        error: details.exception,
        stack: details.stack,
      );
      if (previousOnError != null) {
        previousOnError(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      record(
        scope: 'platform',
        operation: 'uncaught_async',
        error: error,
        stack: stack,
      );
      return false;
    };
  }

  void record({
    required String scope,
    required String operation,
    Object? error,
    StackTrace? stack,
    ProviderErrorType? failureType,
    Map<String, Object?>? data,
  }) {
    try {
      final buffer = StringBuffer()
        ..write(DateTime.now().toUtc().toIso8601String())
        ..write(' [')..write(scope)..write('] ')
        ..write(operation);
      if (failureType != null) {
        buffer
          ..write(' type=')
          ..write(failureType.technicalCode);
      }
      if (error != null) {
        buffer
          ..write(' error=')
          ..write(sanitize(error.toString()));
      }
      if (data != null && data.isNotEmpty) {
        buffer.write(' data={');
        var first = true;
        for (final entry in data.entries) {
          if (!first) buffer.write(', ');
          first = false;
          buffer
            ..write(entry.key)
            ..write('=')
            ..write(sanitize(entry.value?.toString() ?? 'null'));
        }
        buffer.write('}');
      }
      if (stack != null) {
        buffer
          ..write('\n  at ')
          ..write(sanitize(stack.toString().split('\n').take(3).join(' | ')));
      }
      _entries.add(buffer.toString());
      while (_entries.length > maxEntries) {
        _entries.removeAt(0);
      }
    } catch (_) {
      // Diagnostics must never take the app down.
    }
  }

  List<String> get entries => List.unmodifiable(_entries);

  String get summary => _entries.join('\n');

  Future<File> writeExportFile() async {
    final directory = Directory.systemTemp;
    final file = File('${directory.path}${Platform.pathSeparator}$_fileName');
    final header = StringBuffer()
      ..writeln('Flix diagnostics')
      ..writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('Entries: ${_entries.length}')
      ..writeln('---');
    await file.writeAsString('$header$summary\n', flush: true);
    return file;
  }

  /// Shares the sanitized log. Returns false when sharing is unavailable.
  Future<bool> shareExport() async {
    try {
      final file = await writeExportFile();
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Flix diagnostics',
        text: 'Flix playback and download diagnostics.',
      );
      return true;
    } catch (error) {
      record(scope: 'diagnostics', operation: 'share_export', error: error);
      return false;
    }
  }

  static final RegExp _urlPattern = RegExp(r'https?://[^\s)>"]+');
  static final RegExp _sensitiveParam = RegExp(
    r'(sign|signature|token|key|policy|signature|password|secret|api[-_]?key)=[^\s&]+',
    caseSensitive: false,
  );
  static final RegExp _bearer = RegExp(r'Bearer\s+[A-Za-z0-9._\-]+');
  static final RegExp _email = RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.]+\b');

  static String sanitize(String input) {
    var output = input.replaceAllMapped(_urlPattern, (match) {
      final uri = Uri.tryParse(match.group(0)!);
      if (uri == null || uri.host.isEmpty) return '<url>';
      return '${uri.scheme}://${uri.host}/…';
    });
    output = output.replaceAllMapped(_sensitiveParam, (match) {
      return '${match.group(1)}=<redacted>';
    });
    output = output.replaceAll(_bearer, 'Bearer <redacted>');
    output = output.replaceAll(_email, '<email>');
    if (output.length > 600) {
      return '${output.substring(0, 600)}…';
    }
    return output;
  }
}

