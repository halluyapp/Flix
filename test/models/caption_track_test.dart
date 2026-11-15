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
