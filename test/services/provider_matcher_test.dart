import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flix/core/provider/provider_failures.dart';
import 'package:flix/models/media_item.dart';
import 'package:flix/models/provider_match.dart';
import 'package:flix/services/provider_matcher.dart';
import 'package:flix/services/provider_payload.dart';

List<dynamic> _items(String fixture) => ProviderPayload.itemsOf(
      jsonDecode(File('test/fixtures/$fixture').readAsStringSync()),
    );

void main() {
  group('ProviderMatcher confidence and typing', () {
    test('matches a movie and prefers the original audio variant', () {
      final result = ProviderMatcher.select(
        items: _items('provider_search_movie.json'),
        title: 'Inception',
        originalTitle: 'Inception',
        year: 2010,
        isSeries: false,
      );

      expect(result.isMatched, isTrue);
      expect(result.match!.subjectId, '6391474290696802080');
      expect(result.match!.detailPath, 'inception-e1BOR6f19C7');
      expect(result.match!.isDub, isFalse);
      expect(result.match!.confidence, greaterThanOrEqualTo(0.74));
      expect(result.candidates, hasLength(1));
    });

    test('dub and original variants of the same title are not ambiguous', () {
      final result = ProviderMatcher.select(
        items: _items('provider_search_movie.json'),
        title: 'Inception',
        year: 2010,
        isSeries: false,
      );
      expect(result.isMatched, isTrue);
      expect(result.isAmbiguous, isFalse);
    });

    test('matches a TV series and rejects movie records with the same name', () {
      final result = ProviderMatcher.select(
        items: _items('provider_search_tv.json'),
        title: 'Breaking Bad',
        year: 2008,
        isSeries: true,
      );

      expect(result.isMatched, isTrue);
      expect(result.match!.isSeries, isTrue);
      expect(result.match!.subjectId, '1382465867459478920');
      expect(result.match!.detailPath, 'breaking-bad-hindi-mz0TdRUH7E1');
    });

    test('a movie request never matches a TV record', () {
      final result = ProviderMatcher.select(
        items: _items('provider_search_tv.json'),
        title: 'Breaking Bad',
        year: 2008,
        isSeries: false,
      );
      // The provider returns a genuine movie record with that name too, so a
      // movie request must match that record and never a TV entry.
      expect(result.isMatched, isTrue);
      expect(result.match!.isSeries, isFalse);
      expect(result.match!.subjectId, '999000111');
    });

    test('uses the original title when the localized title differs', () {
      final items = [
        {
          'name': 'Der Untergang',
          'subject_id': '300',
          'slug': 'der-untergang',
          'type': 'movie',
          'year': '2004',
          'has_resource': true,
          'audio': 'Original',
          'dub': false,
        }
      ];

      final withoutOriginal = ProviderMatcher.select(
        items: items,
        title: 'Downfall',
        year: 2004,
        isSeries: false,
      );
      expect(withoutOriginal.isMatched, isFalse);

      final withOriginal = ProviderMatcher.select(
        items: items,
        title: 'Downfall',
        originalTitle: 'Der Untergang',
        year: 2004,
        isSeries: false,
      );
      expect(withOriginal.isMatched, isTrue);
      expect(withOriginal.match!.subjectId, '300');
    });

    test('rejects a movie whose release year is far off', () {
      final result = ProviderMatcher.select(
        items: _items('provider_search_movie.json'),
        title: 'Inception',
        year: 2016,
        isSeries: false,
      );
      expect(result.isMatched, isFalse);
    });

    test('a known year disambiguates same-titled remakes', () {
      final classic = ProviderMatcher.select(
        items: _items('provider_search_ambiguous.json'),
        title: 'The Thing',
        year: 1982,
        isSeries: false,
      );
      expect(classic.isMatched, isTrue);
      expect(classic.match!.subjectId, '100');

      final remake = ProviderMatcher.select(
        items: _items('provider_search_ambiguous.json'),
        title: 'The Thing',
        year: 2011,
        isSeries: false,
      );
      expect(remake.isMatched, isTrue);
      expect(remake.match!.subjectId, '200');
    });

    test('an unknown year with two same-titled works asks the viewer', () {
      final result = ProviderMatcher.select(
        items: _items('provider_search_ambiguous.json'),
        title: 'The Thing',
        year: 0,
        isSeries: false,
      );
      expect(result.isMatched, isFalse);
      expect(result.isAmbiguous, isTrue);
      expect(result.candidates, hasLength(2));
    });

    test('never substitutes a subject id for a missing detail path', () {
      final result = ProviderMatcher.select(
        items: _items('provider_search_missing_identifier.json'),
        title: 'Inception',
        year: 2010,
        isSeries: false,
      );
      expect(result.isMatched, isFalse);
      expect(result.failure?.type, ProviderErrorType.missingProviderIdentifier);
    });

    test('ignores provider records marked as having no resource', () {
      final items = [
        {
          'name': 'Inception',
          'subject_id': '1',
          'slug': 'inception',
          'type': 'movie',
          'year': '2010',
          'has_resource': false,
        }
      ];
      expect(
        ProviderMatcher.select(
          items: items,
          title: 'Inception',
          year: 2010,
          isSeries: false,
        ).isMatched,
        isFalse,
      );
    });
  });

  group('ProviderMatcher normalization', () {
    test('normalizes punctuation, diacritics and spacing', () {
      expect(
        ProviderMatcher.normalize('Amélie  &  Friends: Part II'),
        'amelie and friends part ii',
      );
      expect(
        ProviderMatcher.comparisonTitle('Breaking Bad [Hindi] S5'),
        'breaking bad',
      );
      expect(
        ProviderMatcher.comparisonTitle('Movie (2020) 1080p'),
        'movie',
      );
    });

    test('similarity handles containment but not unrelated titles', () {
      expect(ProviderMatcher.similarity('Squid Game', 'Squid Game'), 1.0);
      expect(
        ProviderMatcher.similarity('Squid Game', 'Squid Game Season 2'),
        greaterThanOrEqualTo(0.6),
      );
      expect(ProviderMatcher.similarity('Inception', 'Frozen'), 0.0);
    });
  });

  group('ProviderMatch identifiers', () {
    test('rejects identical subject id and detail path', () {
      final item = MediaItem(
        id: 1,
        title: 'X',
        overview: '',
        voteAverage: 0,
        releaseDate: '2020-01-01',
        mediaType: 'movie',
        genreIds: const [],
        providerSubjectId: '55',
        providerDetailPath: '55',
      );
      expect(ProviderMatch.fromMediaItem(item), isNull);
    });

    test('keeps subject id and detail path distinct', () {
      final item = MediaItem(
        id: 1,
        title: 'X',
        overview: '',
        voteAverage: 0,
        releaseDate: '2020-01-01',
        mediaType: 'movie',
        genreIds: const [],
        providerSubjectId: '55',
        providerDetailPath: 'x-slug',
      );
      final match = ProviderMatch.fromMediaItem(item);
      expect(match, isNotNull);
      expect(match!.subjectId, '55');
      expect(match.detailPath, 'x-slug');
      expect(match.hasDistinctIdentifiers, isTrue);
    });
  });
}
