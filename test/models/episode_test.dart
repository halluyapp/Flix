import 'package:flutter_test/flutter_test.dart';
import 'package:flix/models/episode.dart';

void main() {
  group('Episode release checks', () {
    test('marks past episodes as released', () {
      final ep = Episode.fromJson({
        'episode_number': 1,
        'season_number': 1,
        'name': 'Pilot',
        'air_date': '2024-05-10',
      });
      expect(ep.isReleased, isTrue);
      expect(ep.releaseBadge, isEmpty);
    });

    test('marks future episodes as unreleased with release badge', () {
      final ep = Episode.fromJson({
        'episode_number': 16,
        'season_number': 1,
        'name': 'Season Finale',
        'air_date': '2028-11-29',
      });
      expect(ep.isReleased, isFalse);
      expect(ep.releaseBadge, contains('Coming'));
    });

    test('defaults to released when air date is absent', () {
      final ep = Episode.fromJson({
        'episode_number': 1,
        'season_number': 1,
        'name': 'Unknown Date',
      });
      expect(ep.isReleased, isTrue);
      expect(ep.releaseBadge, isEmpty);
    });

    test('filters unreleased episodes from download batches', () {
      final released = Episode.fromJson({
        'episode_number': 1,
        'season_number': 1,
        'name': 'Episode 1',
        'air_date': '2024-01-01',
      });
      final unreleased = Episode.fromJson({
        'episode_number': 12,
        'season_number': 1,
        'name': 'Episode 12',
        'air_date': '2029-01-01',
      });
      final episodes = [released, unreleased];
      final downloadable = episodes.where((e) => e.isReleased).toList();
      expect(downloadable.length, equals(1));
      expect(downloadable.first.episodeNumber, equals(1));
    });
  });
}
