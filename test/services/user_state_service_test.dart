import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flix/models/media_item.dart';
import 'package:flix/services/user_state_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaItem movie() => MediaItem(
        id: 100,
        title: 'Test Movie',
        overview: 'Overview',
        voteAverage: 8.0,
        releaseDate: '2023-01-01',
        mediaType: 'movie',
        genreIds: const [28],
      );

  MediaItem tvShow() => MediaItem(
        id: 200,
        title: 'Test Drama',
        overview: 'Overview',
        voteAverage: 8.5,
        releaseDate: '2023-01-01',
        mediaType: 'tv',
        genreIds: const [18],
      );

  group('UserStateService watch progress & auto-resume', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('stores and retrieves movie progress', () async {
      final service = UserStateService();
      await service.init();

      final m = movie();
      service.updateProgress(
        item: m,
        season: 0,
        episode: 0,
        positionSeconds: 120,
        durationSeconds: 3600,
      );

      final progress = service.progressFor(m);
      expect(progress, isNotNull);
      expect(progress!.positionSeconds, 120);
      expect(progress.durationSeconds, 3600);
      expect(progress.isCompleted, isFalse);

      final latest = service.latestProgressFor(m);
      expect(latest, isNotNull);
      expect(latest!.positionSeconds, 120);
    });

    test('stores series episode progress and updates latestProgressFor', () async {
      final service = UserStateService();
      await service.init();

      final drama = tvShow();

      // Watch Season 1 Episode 1
      service.updateProgress(
        item: drama,
        season: 1,
        episode: 1,
        episodeTitle: 'Pilot',
        positionSeconds: 500,
        durationSeconds: 2400,
      );

      expect(service.latestProgressFor(drama)?.season, 1);
      expect(service.latestProgressFor(drama)?.episode, 1);
      expect(service.latestProgressFor(drama)?.positionSeconds, 500);

      // Watch Season 2 Episode 3
      service.updateProgress(
        item: drama,
        season: 2,
        episode: 3,
        episodeTitle: 'The Twist',
        positionSeconds: 850,
        durationSeconds: 2400,
      );

      // latestProgressFor should now point to Season 2 Episode 3
      final latest = service.latestProgressFor(drama);
      expect(latest, isNotNull);
      expect(latest!.season, 2);
      expect(latest.episode, 3);
      expect(latest.positionSeconds, 850);

      // Individual episode progress is preserved
      final ep1 = service.progressFor(drama, season: 1, episode: 1);
      expect(ep1, isNotNull);
      expect(ep1!.positionSeconds, 500);

      final ep23 = service.progressFor(drama, season: 2, episode: 3);
      expect(ep23, isNotNull);
      expect(ep23!.positionSeconds, 850);
    });

    test('progressFor with season/episode 0 falls back to latestProgressFor for tv', () async {
      final service = UserStateService();
      await service.init();

      final drama = tvShow();
      service.updateProgress(
        item: drama,
        season: 1,
        episode: 5,
        episodeTitle: 'Midseason',
        positionSeconds: 600,
        durationSeconds: 2400,
      );

      final fallback = service.progressFor(drama);
      expect(fallback, isNotNull);
      expect(fallback!.season, 1);
      expect(fallback.episode, 5);
      expect(fallback.positionSeconds, 600);
    });

    test('completed watch progress is correctly identified', () async {
      final service = UserStateService();
      await service.init();

      final m = movie();
      // 96% watched
      service.updateProgress(
        item: m,
        season: 0,
        episode: 0,
        positionSeconds: 3456,
        durationSeconds: 3600,
      );

      final progress = service.progressFor(m);
      expect(progress, isNotNull);
      expect(progress!.isCompleted, isTrue);
    });
  });
}
