/// One subtitle track returned by the provider.
///
/// Zarhosting labels tracks with `lan`/`lanName`; older mirrors use
/// `language`/`label`. Every spelling seen in provider payloads is accepted,
/// empty values are skipped (never allowed to hide a valid field), and an
/// unknown language stays `und` instead of being labelled English.
class CaptionTrack {
  final String id;

  /// Normalized lowercase language code (`en`, `zh-hans`, `pt-br`), or `und`.
  final String language;
  final String languageName;

  /// Subtitle file URL exactly as the provider supplied it (usually signed).
  final String url;
  final bool isDefault;
  final int sizeBytes;

  /// `srt`, `vtt`, `ass` or `ssa` when the provider or the URL declares it,
  /// otherwise empty. The downloaded file's real format is always re-checked
  /// from its content before it is saved.
  final String format;

  /// Provider-declared timing offset in milliseconds (0 when absent).
  final int delayMs;

  CaptionTrack({
    required this.id,
    required this.language,
    required this.languageName,
    required this.url,
    this.isDefault = false,
    this.sizeBytes = 0,
    this.format = '',
    this.delayMs = 0,
  });

  // Field spellings observed across Zarhosting and older MovieBox-style
  // mirrors. Order matters: the first non-empty value wins.
  static const List<String> languageKeys = [
    'lan',
    'language',
    'lang',
    'srclang',
    'languageCode',
    'language_code',
    'locale',
  ];
  static const List<String> nameKeys = [
    'lanName',
    'languageName',
    'language_name',
    'label',
    'name',
    'title',
  ];
  static const List<String> urlKeys = [
    'url',
    'subtitleUrl',
    'subtitle_url',
    'file',
    'src',
    'link',
    'downloadUrl',
    'download_url',
  ];
  static const List<String> idKeys = [
    'id',
    'subtitleId',
    'subtitle_id',
    'captionId',
    'caption_id',
  ];
  static const List<String> sizeKeys = [
    'size',
    'size_bytes',
    'sizeBytes',
    'fileSize',
    'file_size',
  ];
  static const List<String> formatKeys = [
    'format',
    'ext',
    'extension',
    'mimeType',
    'mime_type',
    'mime',
    'contentType',
  ];
  static const List<String> defaultKeys = [
    'is_default',
    'isDefault',
    'default',
    'default_track',
  ];
  static const List<String> delayKeys = ['delay', 'delay_ms', 'delayMs'];

  static const Map<String, String> _languageAliases = {
    'eng': 'en',
    'chi': 'zh',
    'zho': 'zh',
    'kor': 'ko',
    'jpn': 'ja',
    'spa': 'es',
    'fre': 'fr',
    'fra': 'fr',
    'ger': 'de',
    'deu': 'de',
    'ara': 'ar',
    'ind': 'id',
    'tha': 'th',
    'vie': 'vi',
    'por': 'pt',
    'rus': 'ru',
    'tur': 'tr',
    'hin': 'hi',
    'msa': 'ms',
    'may': 'ms',
  };

  static const Map<String, String> _nameToCode = {
    'english': 'en',
    'chinese': 'zh',
    'simplified chinese': 'zh-hans',
    'traditional chinese': 'zh-hant',
    'korean': 'ko',
    'japanese': 'ja',
    'spanish': 'es',
    'french': 'fr',
    'portuguese': 'pt',
    'arabic': 'ar',
    'indonesian': 'id',
    'thai': 'th',
    'vietnamese': 'vi',
    'russian': 'ru',
    'hindi': 'hi',
    'turkish': 'tr',
    'german': 'de',
    'italian': 'it',
    'malay': 'ms',
    'filipino': 'fil',
    'العربية': 'ar',
    '中文': 'zh',
    '한국어': 'ko',
    '日本語': 'ja',
  };

  static const Map<String, String> _codeToName = {
    'en': 'English',
    'zh': 'Chinese',
    'zh-hans': 'Simplified Chinese',
    'zh-hant': 'Traditional Chinese',
    'ko': 'Korean',
    'ja': 'Japanese',
    'es': 'Spanish',
    'fr': 'French',
    'pt': 'Portuguese',
    'ar': 'Arabic',
    'id': 'Indonesian',
    'th': 'Thai',
    'vi': 'Vietnamese',
    'ru': 'Russian',
    'hi': 'Hindi',
    'tr': 'Turkish',
    'de': 'German',
    'it': 'Italian',
    'ms': 'Malay',
    'fil': 'Filipino',
  };

  /// First non-empty text value among [keys]. Nested objects and lists are
  /// never stringified into a value.
  static String? textOf(Map<dynamic, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null || value is Map || value is List) continue;
      final text = value.toString().trim();
      if (text.isEmpty || text.toLowerCase() == 'null') continue;
      return text;
    }
    return null;
  }

  /// Canonical language code. Returns an empty string when none is usable.
  static String normalizeLanguage(String? raw) {
    if (raw == null) return '';
    var value = raw.trim().toLowerCase().replaceAll('_', '-');
    if (value.isEmpty || value == 'und' || value == 'unknown') return '';
    value = value.replaceAll(RegExp(r'[^a-z0-9-]'), '');
    if (value.isEmpty || value.length > 16) return '';
    return _languageAliases[value] ?? value;
  }

  /// Maps a readable language name (for example "English") to its code, for
  /// providers that omit the code. Unknown names yield an empty string.
  static String languageFromName(String name) {
    final key = name.trim().toLowerCase();
    return _nameToCode[key] ?? _nameToCode[name.trim()] ?? '';
  }

  static String _displayNameFor(String language) =>
      _codeToName[language] ?? language.toUpperCase();

  /// Format from explicit metadata first, then from the URL path or a
  /// `format=` query value. Returns '' when nothing declares a format.
  static String resolveFormat(Map<dynamic, dynamic> json, String url) {
    final declared = normalizeFormat(textOf(json, formatKeys));
    if (declared.isNotEmpty) return declared;
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final fromQuery = normalizeFormat(uri.queryParameters['format']);
    if (fromQuery.isNotEmpty) return fromQuery;
    return normalizeFormat(uri.path.toLowerCase());
  }

  static String normalizeFormat(String? raw) {
    if (raw == null) return '';
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return '';
    // Anchored so MIME types (text/vtt, application/x-subrip) and file
    // extensions both match without catching unrelated words.
    if (RegExp(r'(^|[/.])(webvtt|vtt)$').hasMatch(value)) return 'vtt';
    if (RegExp(r'(^|[/.])(srt|subrip)$').hasMatch(value)) return 'srt';
    if (value == 'ass' ||
        value.endsWith('.ass') ||
        value == 'ssa' ||
        value.endsWith('.ssa') ||
        value.contains('x-ssa') ||
        value.contains('x-ass')) {
      return value.contains('ssa') ? 'ssa' : 'ass';
    }
    if (value.endsWith('.ttml') || value.endsWith('.dfxp') || value == 'ttml') {
      return 'ttml';
    }
    return '';
  }

  static bool _boolValue(Map<dynamic, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (const ['true', '1', 'yes'].contains(normalized)) return true;
      }
    }
    return false;
  }

  static int _parseInt(String? value) {
    if (value == null) return 0;
    final match = RegExp(r'-?\d+').firstMatch(value);
    if (match == null) return 0;
    return int.tryParse(match.group(0)!) ?? 0;
  }

  static int _parseSize(String? value) {
    if (value == null) return 0;
    final match = RegExp(r'\d+').firstMatch(value);
    return (int.tryParse(match?.group(0) ?? '') ?? 0).clamp(0, 1 << 62);
  }

  /// URL without its query string, used to recognise the same subtitle file
  /// when a signed link is refreshed.
  static String identityUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return url.trim();
    return '${uri.host.toLowerCase()}${uri.path}';
  }

  /// Deterministic 32-bit FNV-1a identifier. Unlike `String.hashCode` it is
  /// stable across app launches, so persisted selections keep working.
  static String stableId(String seed) {
    var hash = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  factory CaptionTrack.fromJson(Map<String, dynamic> json) {
    final rawLanguage = textOf(json, languageKeys);
    final rawName = textOf(json, nameKeys);
    var language = normalizeLanguage(rawLanguage);
    if (language.isEmpty && rawName != null) {
      language = languageFromName(rawName);
    }
    if (language.isEmpty) language = 'und';

    final url = (textOf(json, urlKeys) ?? '').trim();
    final id = textOf(json, idKeys) ??
        stableId('$language|${identityUrl(url)}');

    return CaptionTrack(
      id: id,
      language: language,
      languageName: rawName ?? _displayNameFor(language),
      url: url,
      isDefault: _boolValue(json, defaultKeys),
      sizeBytes: _parseSize(textOf(json, sizeKeys)),
      format: resolveFormat(json, url),
      delayMs: _parseInt(textOf(json, delayKeys)),
    );
  }

  factory CaptionTrack.fromStorageJson(Map<String, dynamic> json) =>
      CaptionTrack.fromJson(json);

  /// Why this track cannot be fetched, or null when its link is usable.
  /// Only https links with a host and no embedded credentials pass.
  String? get rejectionReason {
    final value = url.trim();
    if (value.isEmpty) return 'missing_url';
    if (value.length > 2048 || RegExp(r'\s').hasMatch(value)) {
      return 'unsafe_url';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return 'invalid_url';
    if (uri.scheme != 'https') return 'insecure_url';
    if (uri.userInfo.isNotEmpty) return 'unsafe_url';
    return null;
  }

  bool get isSecure => rejectionReason == null;

  /// Host only, for diagnostics. The signed path and query are never logged.
  String get host => Uri.tryParse(url)?.host ?? '';

  bool get isSubtitleFormat {
    if (format.isNotEmpty) return true;
    final lower = url.toLowerCase();
    return lower.contains('.srt') ||
        lower.contains('.vtt') ||
        lower.contains('.webvtt') ||
        lower.contains('.ass') ||
        lower.contains('.ssa') ||
        lower.contains('format=srt') ||
        lower.contains('format=vtt');
  }

  /// Declared format (`srt`, `vtt`, `ass`, `ssa`), or '' when undeclared.
  /// Saved files take their extension from the downloaded content instead.
  String get extension => format;

  /// Keys that identify the same subtitle regardless of signed query values.
  String get identityKey => '$language|${identityUrl(url)}';

  /// Removes duplicate tracks while keeping distinct tracks of the same
  /// language (for example a regular and a hearing-impaired English track).
  static List<CaptionTrack> dedupe(Iterable<CaptionTrack> tracks) {
    final seenIds = <String>{};
    final seenIdentities = <String>{};
    final result = <CaptionTrack>[];
    for (final track in tracks) {
      if (!seenIds.add('${track.language}|${track.id}')) continue;
      if (track.url.isNotEmpty && !seenIdentities.add(track.identityKey)) {
        continue;
      }
      result.add(track);
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'lan': language,
        'lanName': languageName,
        'url': url,
        'isDefault': isDefault,
        'size': sizeBytes,
        'format': format,
        'delay': delayMs,
      };
}
