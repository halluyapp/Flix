/// Defensive readers for provider API payloads (MovieBox H5 API and legacy formats).
///
/// The public API returns items under `data.items` or `data.list`, but the same
/// data can arrive wrapped differently across endpoints and mirrors. These
/// helpers accept every shape seen in the live contract without turning a
/// malformed response into a silent empty result.
class ProviderPayload {
  const ProviderPayload._();

  static Map<String, dynamic> asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  /// Unwraps a single `data` envelope.
  static Map<String, dynamic> bodyOf(dynamic decoded) {
    final root = asMap(decoded);
    final data = root['data'];
    if (data is Map) return asMap(data);
    return root;
  }

  /// Finds the first list of provider items anywhere in a search response.
  static List<dynamic> itemsOf(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is! Map) return const [];
    for (final key in const [
      'items',
      'results',
      'subjects',
      'list',
      'data',
    ]) {
      final value = decoded[key];
      if (value is List) return value;
      if (value is Map) {
        final nested = itemsOf(value);
        if (nested.isNotEmpty) return nested;
      }
    }
    return const [];
  }

  static List<dynamic> listOf(dynamic value) =>
      value is List ? value : const <dynamic>[];

  static String string(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty && text.toLowerCase() != 'null') return text;
    }
    return '';
  }

  /// Extracts a cover or poster URL, handling nested object shapes like
  /// `{"cover": {"url": "https://..."}}` common in MovieBox H5 API.
  static String posterUrl(Map<String, dynamic> map) {
    final cover = map['cover'];
    if (cover is Map) {
      final url = cover['url']?.toString().trim() ?? '';
      if (url.isNotEmpty && url.toLowerCase() != 'null') return url;
    } else if (cover is String && cover.trim().isNotEmpty && cover.toLowerCase() != 'null') {
      return cover.trim();
    }
    return string(map, const [
      'poster_url',
      'posterUrl',
      'cover_url',
      'coverUrl',
      'poster',
      'image',
      'thumb',
      'thumbnail',
    ]);
  }

  static bool? optionalBool(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (const ['true', 'yes', '1', 'available'].contains(normalized)) {
          return true;
        }
        if (const ['false', 'no', '0', 'unavailable'].contains(normalized)) {
          return false;
        }
      }
    }
    return null;
  }

  static int integer(Map<String, dynamic> map, List<String> keys,
      {int fallback = 0}) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      if (value is int) return value;
      if (value is num) return value.toInt();
      final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(value.toString());
      if (match != null) {
        final parsed = double.tryParse(match.group(0)!);
        if (parsed != null) return parsed.round();
      }
    }
    return fallback;
  }

  /// Provider years arrive as `year`, `release_year`, `releaseYear` or an ISO release date.
  static int year(Map<String, dynamic> map) {
    for (final key in const ['year', 'release_year', 'releaseYear']) {
      final raw = map[key]?.toString().trim() ?? '';
      if (raw.isNotEmpty) {
        final parsed = int.tryParse(raw.length >= 4 ? raw.substring(0, 4) : raw);
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    final rawDate = string(map, const ['release_date', 'releaseDate']);
    if (rawDate.length >= 4) {
      return int.tryParse(rawDate.substring(0, 4)) ?? 0;
    }
    return 0;
  }

  static List<String> stringList(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is List) {
        final items = value
            .map((entry) => entry?.toString().trim() ?? '')
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false);
        if (items.isNotEmpty) return items;
      } else if (value is String && value.trim().isNotEmpty) {
        return value
            .split(',')
            .map((entry) => entry.trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false);
      }
    }
    return const [];
  }
}
