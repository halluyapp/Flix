import 'package:flutter_test/flutter_test.dart';
import 'package:flix/models/media_item.dart';

void main() {
  group('MediaItem Model Tests', () {
    test('parses movie JSON correctly', () {
      final json = {
        'id': 12345,
        'title': 'Squid Game',
        'overview': 'Survival competition in Seoul.',
        'poster_path': '/poster.jpg',
        'backdrop_path': '/backdrop.jpg',
        'vote_average': 8.4,
        'release_date': '2021-09-17',
        'media_type': 'tv',
        'genre_ids': [18, 9648],
      };

      final item = MediaItem.fromJson(json);

      expect(item.id, 12345);
      expect(item.title, 'Squid Game');
      expect(item.mediaType, 'tv');
      expect(item.releaseYear, 2021);
      expect(item.voteAverage, 8.4);
      expect(item.matchScore, 84);
      expect(item.posterUrl, contains('https://image.tmdb.org/t/p/w500/poster.jpg'));
      // w780 keeps a full-width backdrop affordable to decode on a 2 GB phone.
      expect(item.backdropUrl, contains('https://image.tmdb.org/t/p/w780/backdrop.jpg'));
    });

    test('handles fallback when fields are missing or null', () {
      final json = {
        'id': 999,
        'name': 'Untitled Series',
        'first_air_date': '2024-01-01',
      };

      final item = MediaItem.fromJson(json, defaultType: 'tv');

      expect(item.id, 999);
      expect(item.title, 'Untitled Series');
      expect(item.releaseYear, 2024);
      expect(item.overview, '');
      expect(item.voteAverage, 0.0);
    });
  });
}
