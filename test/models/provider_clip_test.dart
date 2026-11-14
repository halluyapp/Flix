import 'package:flutter_test/flutter_test.dart';
import 'package:flix/models/provider_clip.dart';

void main() {
  group('ProviderClip.fromProviderJson', () {
    final validRecord = <String, dynamic>{
      'name': 'Piper',
      'subject_id': '3422627224854347992',
      'slug': 'piper-MWpLJDtFP44',
      'year': '2016',
      'rating': '8.3',
      'genre': 'Animation,Short,Family',
      'type': 'movie',
      'poster_url': 'https://cdn.example.test/piper.jpg',
      'country': 'United States',
      'has_resource': true,
    };

    test('accepts a resource-backed movie explicitly tagged Short', () {
      final clip = ProviderClip.fromProviderJson(validRecord);

      expect(clip, isNotNull);
      expect(clip!.title, 'Piper');
      expect(clip.detailPath, 'piper-MWpLJDtFP44');
      expect(clip.year, 2016);
      expect(clip.toMediaItem().mediaType, 'movie');
      expect(clip.toMediaItem().posterUrl, 'https://cdn.example.test/piper.jpg');
      expect(clip.toMediaItem().providerSubjectId, clip.subjectId);
      expect(clip.toMediaItem().providerDetailPath, clip.detailPath);
      expect(clip.toMediaItem().id, lessThan(0));
    });

    test('rejects query-only matches without the exact Short genre', () {
      final feature = {
        ...validRecord,
        'genre': 'Animation,Adventure,Comedy',
      };

      expect(ProviderClip.fromProviderJson(feature), isNull);
    });

    test('rejects series even when its genres include Short', () {
      final series = {
        ...validRecord,
        'type': 'tv',
      };

      expect(ProviderClip.fromProviderJson(series), isNull);
    });

    test('rejects explicit adult genres', () {
      final adultShort = {
        ...validRecord,
        'genre': 'Animation,Short,Adult',
      };

      expect(ProviderClip.fromProviderJson(adultShort), isNull);
    });

    test('rejects explicit adult titles even if the genre tag is incomplete', () {
      final explicit = {
        ...validRecord,
        'name': 'Hentai Short',
        'genre': 'Animation,Short',
      };

      expect(ProviderClip.fromProviderJson(explicit), isNull);
    });

    test('rejects provider adult flags even when genres otherwise qualify', () {
      final flagged = {
        ...validRecord,
        'adult': true,
      };

      expect(ProviderClip.fromProviderJson(flagged), isNull);
    });

    test('rejects adult age ratings even when genres otherwise qualify', () {
      final restricted = {
        ...validRecord,
        'age_rating': 'NC-17',
      };

      expect(ProviderClip.fromProviderJson(restricted), isNull);
    });

    test('rejects entries the provider does not mark as playable', () {
      final unavailable = {
        ...validRecord,
        'has_resource': false,
      };

      expect(ProviderClip.fromProviderJson(unavailable), isNull);
    });

    test('rejects unknown numeric provider media types', () {
      final unknownType = {
        ...validRecord,
        'type': 5,
      };

      expect(ProviderClip.fromProviderJson(unknownType), isNull);
    });
  });
}
