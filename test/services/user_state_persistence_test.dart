import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flix/models/media_item.dart';
import 'package:flix/services/user_state_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaItem movie({int id = 100}) => MediaItem(
        id: id,
        title: 'Test Movie $id',
        overview: 'Overview',
        voteAverage: 8.0,
        releaseDate: '2023-01-01',
        mediaType: 'movie',
        genreIds: const [28],
      );

  MediaItem drama({int id = 200}) => MediaItem(
        id: id,
        title: 'Test Drama $id',
        overview: 'Overview',
        voteAverage: 8.5,
        releaseDate: '2023-01-01',
        mediaType: 'tv',
        genreIds: const [18],
      );

  group('persistence and resume', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('movie progress is persisted across an app restart', () async {
      final m = movie();
      final first = UserStateService();
      await first.init();
      await first.updateProgress(
        item: m,
        positionSeconds: 1111,
        durationSeconds: 4000,
      );
      await first.flush();

      final second = UserStateService();
      await second.init();
      final saved = second.progressFor(m);
      expect(saved, isNotNull);
      expect(saved!.positionSeconds, 1111);
      expect(saved.durationSeconds, 4000);
      expect(saved.isCompleted, isFalse);
      expect(second.latestProgressFor(m)?.positionSeconds, 1111);
    });

    test('tv episode progress is separate per episode and survives restart',
        () async {
      final d = drama();
      final first = UserStateService();
      await first.init();
      await first.updateProgress(
        item: d,
        season: 1,
        episode: 2,
        positionSeconds: 300,
        durationSeconds: 2400,
      );
      await first.updateProgress(
        item: d,
        season: 1,
        episode: 3,
        positionSeconds: 1800,
        durationSeconds: 2400,
      );
      await first.flush();

      final second = UserStateService();
      await second.init();
      final ep2 = second.progressFor(d, season: 1, episode: 2);
      final ep3 = second.progressFor(d, season: 1, episode: 3);
      expect(ep2?.positionSeconds, 300);
      expect(ep3?.positionSeconds, 1800);
      // Resuming motion: the latest unfinished episode is the resume target.
      expect(second.latestProgressFor(d)?.episode, 3);
    });

    test('a completed episode is not offered as the resume target', () async {
      final d = drama();
      final first = UserStateService();
      await first.init();
      await first.updateProgress(
        item: d,
        season: 1,
        episode: 1,
        positionSeconds: 2280,
        durationSeconds: 2400, // 95% -> completed
      );
      await first.updateProgress(
        item: d,
        season: 1,
        episode: 2,
        positionSeconds: 900,
        durationSeconds: 2400,
      );
      await first.flush();

      final second = UserStateService();
      await second.init();
      final resume = second.latestProgressFor(d);
      expect(resume, isNotNull);
      expect(resume!.episode, 2);
      expect(resume.isCompleted, isFalse);
      // The completed episode keeps its own record, only its resume is gone.
      final completed = second.progressFor(d, season: 1, episode: 1);
      expect(completed, isNotNull);
      expect(completed!.isCompleted, isTrue);
    });

    test('progress never resumes above the 95% completed threshold', () async {
      final m = movie(id: 101);
      final service = UserStateService();
      await service.init();
      await service.updateProgress(
        item: m,
        positionSeconds: 3800,
        durationSeconds: 4000, // 95%
      );
      await service.flush();
      final saved = service.progressFor(m);
      expect(saved!.isCompleted, isTrue);
    });

    test('progress is isolated per profile and survives a profile switch',
        () async {
      SharedPreferences.setMockInitialValues({});
      final d = drama(id: 300);
      final service = UserStateService();
      await service.init();

      // Profile 2 (Alex) starts empty.
      await service.setProfile(service.profiles[1]);
      await service.updateProgress(
        item: d,
        season: 1,
        episode: 4,
        positionSeconds: 700,
        durationSeconds: 2400,
      );
      await service.flush();

      // Switching back to profile 1 must not see profile 2's progress.
      await service.setProfile(service.profiles[0]);
      expect(service.progressFor(d, season: 1, episode: 4), isNull);
      expect(service.continueWatching, isEmpty);

      // Switching forward again restores it from disk.
      await service.setProfile(service.profiles[1]);
      final saved = service.progressFor(d, season: 1, episode: 4);
      expect(saved, isNotNull);
      expect(saved!.positionSeconds, 700);

      // A fresh instance on this profile (app restart) still finds it.
      final restart = UserStateService();
      await restart.init();
      final restarted = restart.progressFor(d, season: 1, episode: 4);
      expect(restarted, isNotNull);
      expect(restarted!.positionSeconds, 700);
    });

    test('the active profile is chosen by the caller, not by stale saves',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = UserStateService();
      await service.init();
      // Switch to profile 2 (Alex)
      await service.setProfile(service.profiles[1]);
      await service.updateProgress(
        item: movie(id: 301),
        positionSeconds: 100,
        durationSeconds: 1000,
      );
      await service.flush();
      // The persisted active profile id must match the selected profile.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('flix_active_profile_id'), '2');

      // A fresh instance remembers profile 2, not the default.
      final restart = UserStateService();
      await restart.init();
      expect(restart.currentProfile.id, '2');
    });
  });
}
