import 'package:flutter_test/flutter_test.dart';
import 'package:flix/services/episode_navigator.dart';

void main() {
  group('EpisodeNavigator next', () {
    test('advances within the current season using real episode numbers', () {
      final next = EpisodeNavigator.next(
        currentSeason: 1,
        currentEpisode: 1,
        episodesBySeason: {
          1: [1, 2, 4],
        },
      );
      expect(next, const EpisodePointer(1, 2));
    });

    test('skips missing episode numbers', () {
      final next = EpisodeNavigator.next(
        currentSeason: 1,
        currentEpisode: 2,
        episodesBySeason: {
          1: [1, 2, 4],
        },
      );
      expect(next, const EpisodePointer(1, 4));
    });

    test('moves to the first episode of the next season at a boundary', () {
      final next = EpisodeNavigator.next(
        currentSeason: 2,
        currentEpisode: 10,
        episodesBySeason: {
          1: [1, 2],
          2: [1, 10],
          3: [1, 2, 3],
        },
        seasonOrder: [1, 2, 3],
      );
      expect(next, const EpisodePointer(3, 1));
    });

    test('skips a season with no episode data', () {
      final next = EpisodeNavigator.next(
        currentSeason: 1,
        currentEpisode: 10,
        episodesBySeason: {
          1: [1, 10],
          2: <int>[],
          3: [5, 6],
        },
        seasonOrder: [1, 2, 3],
      );
      expect(next, const EpisodePointer(3, 5));
    });

    test('supports shows that do not start at season one', () {
      final next = EpisodeNavigator.next(
        currentSeason: 0,
        currentEpisode: 1,
        episodesBySeason: {
          0: [1, 2],
          1: [1],
        },
        seasonOrder: [0, 1],
      );
      expect(next, const EpisodePointer(0, 2));
    });

    test('returns null at the final episode', () {
      final next = EpisodeNavigator.next(
        currentSeason: 2,
        currentEpisode: 3,
        episodesBySeason: {
          2: [1, 2, 3],
        },
      );
      expect(next, isNull);
    });

    test('returns null when no episode data exists', () {
      expect(
        EpisodeNavigator.next(
          currentSeason: 1,
          currentEpisode: 1,
          episodesBySeason: const {},
        ),
        isNull,
      );
    });
  });

  group('EpisodeNavigator previous', () {
    test('steps back within a season', () {
      expect(
        EpisodeNavigator.previous(
          currentSeason: 1,
          currentEpisode: 4,
          episodesBySeason: {
            1: [1, 2, 4],
          },
        ),
        const EpisodePointer(1, 2),
      );
    });

    test('crosses into the previous season', () {
      expect(
        EpisodeNavigator.previous(
          currentSeason: 2,
          currentEpisode: 1,
          episodesBySeason: {
            1: [1, 2, 3],
            2: [1],
          },
        ),
        const EpisodePointer(1, 3),
      );
    });

    test('returns null at the first episode', () {
      expect(
        EpisodeNavigator.previous(
          currentSeason: 1,
          currentEpisode: 1,
          episodesBySeason: {
            1: [1, 2],
          },
        ),
        isNull,
      );
    });
  });
}
