import 'package:flutter_test/flutter_test.dart';
import 'package:flix/models/caption_track.dart';

void main() {
  group('CaptionTrack', () {
    test('maps the provider lan/lanName fields', () {
      final track = CaptionTrack.fromJson({
        'id': '5968867068744189216',
        'lan': 'ar',
        'lanName': 'العربية',
        'url': 'https://subs.example.com/a.srt',
        'size': '111974',
      });

      expect(track.language, 'ar');
      expect(track.languageName, 'العربية');
      expect(track.sizeBytes, 111974);
      expect(track.isSecure, isTrue);
      expect(track.extension, 'srt');
      expect(track.isSubtitleFormat, isTrue);
    });

    test('supports older language/label spellings', () {
      final track = CaptionTrack.fromJson({
        'language': 'en',
        'label': 'English',
        'subtitleUrl': 'https://subs.example.com/b.vtt',
      });
      expect(track.language, 'en');
      expect(track.languageName, 'English');
      expect(track.extension, 'vtt');
    });

    test('does not mislabel an unknown language as English', () {
      final track = CaptionTrack.fromJson({
        'url': 'https://subs.example.com/c.srt',
      });
      expect(track.language, 'und');
      expect(track.languageName, 'UND');
    });

    test('rejects insecure subtitle URLs', () {
      final track = CaptionTrack.fromJson({
        'lan': 'en',
        'url': 'http://subs.example.com/c.srt',
      });
      expect(track.isSecure, isFalse);
    });

    test('an empty field never hides a valid later field', () {
      final track = CaptionTrack.fromJson({
        'lan': '',
        'language': 'en',
        'lanName': '',
        'label': 'English',
        'url': 'https://subs.example.com/e.srt',
      });
      expect(track.language, 'en');
      expect(track.languageName, 'English');
    });

    test('the same file gets the same id on every load', () {
      Map<String, dynamic> raw() => {
            'lan': 'en',
            'url': 'https://subs.example.com/stable.srt?token=one',
          };
      final first = CaptionTrack.fromJson(raw());
      final second = CaptionTrack.fromJson(raw());
      expect(first.id, isNotEmpty);
      expect(first.id, second.id);
    });

    test('keeps two tracks in the same language when their files differ', () {
      final tracks = [
        CaptionTrack.fromJson({
          'lan': 'en',
          'url': 'https://subs.example.com/en-1.srt',
        }),
        CaptionTrack.fromJson({
          'lan': 'en',
          'url': 'https://subs.example.com/en-2.srt',
        }),
      ];
      expect(CaptionTrack.dedupe(tracks), hasLength(2));
    });

    test('drops a track whose file is listed twice', () {
      final tracks = [
        CaptionTrack.fromJson({
          'lan': 'en',
          'url': 'https://subs.example.com/same.srt?token=a',
        }),
        CaptionTrack.fromJson({
          'lan': 'en',
          'url': 'https://subs.example.com/same.srt?token=b',
        }),
      ];
      expect(CaptionTrack.dedupe(tracks), hasLength(1));
    });

    test('accepts a format declared by the URL without an extension', () {
      final track = CaptionTrack.fromJson({
        'lan': 'en',
        'url': 'https://subs.example.com/file?format=vtt&token=abc',
      });
      expect(track.extension, 'vtt');
      expect(track.isSubtitleFormat, isTrue);
    });

    test('an unrecognized URL is not rejected just for lacking .srt/.vtt', () {
      final track = CaptionTrack.fromJson({
        'lan': 'en',
        'url': 'https://subs.example.com/download/12345?sig=abc',
      });
      expect(track.rejectionReason, isNull);
      expect(track.isSecure, isTrue);
    });

    test('round-trips through storage JSON', () {
      final track = CaptionTrack(
        id: 'x',
        language: 'fr',
        languageName: 'Français',
        url: 'https://subs.example.com/fr.srt',
        isDefault: true,
      );
      final restored = CaptionTrack.fromStorageJson(track.toJson());
      expect(restored.language, 'fr');
      expect(restored.languageName, 'Français');
      expect(restored.isDefault, isTrue);
    });
  });
}
