import 'dart:convert';

import '../core/provider/provider_failures.dart';
import '../models/caption_load.dart';
import '../models/caption_track.dart';
import 'provider_payload.dart';

/// Explicit adapter from a Zarhosting caption response to [CaptionLoad].
///
/// The adapter reads only the collection shapes listed below. It never walks
/// every nested object, so unrelated metadata (poster URLs, related titles,
/// recommendation lists) cannot be mistaken for subtitles.
///
/// Supported collection shapes, checked in this order:
///  * a list under `captions`, `subtitles`, `extCaptions`, `ext_captions`,
///    `subtitle_tracks`, `subtitleTracks`, `tracks`, `caption_list`,
///    `captionList`, or `items`;
///  * a wrapper object under one of those keys holding a list under
///    `items`, `list`, `records`, `data`, `captions`, `subtitles` or `tracks`;
///  * a single track object under one of those keys;
///  * an object keyed by language code, whose values are track objects.
///
/// Errors (`error` text or `success: false`) raise [ProviderException]. A
/// response with no readable collection is [CaptionLoadStatus.unsupported];
/// a readable empty collection is [CaptionLoadStatus.empty].
class CaptionResponseAdapter {
  const CaptionResponseAdapter._();

  static const List<String> _collectionKeys = [
    'captions',
    'subtitles',
    'extCaptions',
    'ext_captions',
    'subtitle_tracks',
    'subtitleTracks',
    'tracks',
    'caption_list',
    'captionList',
    'items',
  ];

  static const List<String> _wrapperKeys = [
    'items',
    'list',
    'records',
    'data',
    'captions',
    'subtitles',
    'tracks',
  ];

  static CaptionLoad parse(dynamic decoded) {
    if (decoded is! Map) {
      throw ProviderException(
        ProviderErrorType.invalidProviderResponse,
        'The provider returned subtitle data in an unexpected shape.',
        diagnostic: 'root ${decoded.runtimeType}',
      );
    }
    final root = ProviderPayload.bodyOf(decoded);
    _throwIfProviderError(root);

    final found = _findCollection(root);
    if (found == null) {
      final count = root['count'];
      if (count is num && count == 0) {
        return CaptionLoad(
          status: CaptionLoadStatus.empty,
          shape: 'count_zero',
        );
      }
      return CaptionLoad(
        status: CaptionLoadStatus.unsupported,
        shape: 'no_collection',
        rejectionReasons: const ['no_collection'],
      );
    }

    if (found.entries.isEmpty) {
      return CaptionLoad(
        status: CaptionLoadStatus.empty,
        shape: found.shape,
      );
    }

    final tracks = <CaptionTrack>[];
    final reasons = <String>{};
    var rejected = 0;
    for (final raw in found.entries) {
      if (raw is! Map) {
        rejected++;
        reasons.add('not_an_object');
        continue;
      }
      final track = CaptionTrack.fromJson(Map<String, dynamic>.from(raw));
      final reason = track.rejectionReason;
      if (reason != null) {
        rejected++;
        reasons.add(reason);
        continue;
      }
      tracks.add(track);
    }

    final unique = CaptionTrack.dedupe(tracks);
    if (unique.length < tracks.length) reasons.add('duplicate');

    if (unique.isEmpty) {
      // Records existed but none were usable: that is a parsing problem,
      // never a silent "no subtitles".
      return CaptionLoad(
        status: CaptionLoadStatus.unsupported,
        shape: found.shape,
        rawCount: found.entries.length,
        rejectedCount: rejected,
        rejectionReasons: reasons.toList(growable: false),
      );
    }

    return CaptionLoad(
      status: CaptionLoadStatus.loaded,
      tracks: List.unmodifiable(unique),
      shape: found.shape,
      rawCount: found.entries.length,
      rejectedCount: rejected,
      rejectionReasons: reasons.toList(growable: false),
    );
  }

  static void _throwIfProviderError(Map<String, dynamic> root) {
    final error = ProviderPayload.string(root, const ['error']);
    final failed = root['success'] == false;
    if (error.isEmpty && !failed) return;
    final code = error.isEmpty ? 'success_false' : error;
    throw ProviderException(
      code == 'upstream_error'
          ? ProviderErrorType.providerUnavailable
          : ProviderErrorType.invalidProviderResponse,
      'The provider could not return subtitles for this episode.',
      diagnostic: 'error=${code.substring(0, code.length.clamp(0, 48))}',
    );
  }

  static _FoundCollection? _findCollection(Map<String, dynamic> root) {
    for (final key in _collectionKeys) {
      final value = root[key];
      if (value == null) continue;

      if (value is String && value.trim().startsWith('[')) {
        // Some mirrors double-encode the list as a JSON string.
        try {
          final decoded = jsonDecode(value);
          if (decoded is List) {
            return _FoundCollection(decoded, 'json_string:$key');
          }
        } catch (_) {
          // Not JSON after all; keep looking.
        }
        continue;
      }

      if (value is List) {
        return _FoundCollection(value, 'list:$key');
      }

      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        if (_looksLikeTrack(map)) {
          return _FoundCollection([map], 'single:$key');
        }
        for (final wrapper in _wrapperKeys) {
          final nested = map[wrapper];
          if (nested is List) {
            return _FoundCollection(nested, 'nested:$key.$wrapper');
          }
        }
        if (map.isEmpty) {
          return _FoundCollection(const [], 'empty_object:$key');
        }
        if (map.values.every((entry) => entry is Map && _looksLikeTrack(entry))) {
          final entries = <Map<String, dynamic>>[];
          map.forEach((languageKey, entry) {
            final copy = Map<String, dynamic>.from(entry as Map);
            copy.putIfAbsent('lan', () => languageKey);
            entries.add(copy);
          });
          return _FoundCollection(entries, 'by_language:$key');
        }
      }
    }
    return null;
  }

  static bool _looksLikeTrack(Map<dynamic, dynamic> map) =>
      CaptionTrack.textOf(map, CaptionTrack.urlKeys) != null;
}

class _FoundCollection {
  final List<dynamic> entries;
  final String shape;

  const _FoundCollection(this.entries, this.shape);
}
