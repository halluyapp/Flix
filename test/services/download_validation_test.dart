import 'package:flutter_test/flutter_test.dart';
import 'package:flix/services/download_validation.dart';

void main() {
  group('DownloadValidation file naming', () {
    test('builds deterministic, collision-safe video names', () {
      final first = DownloadValidation.videoFileName(
        title: 'The Matrix',
        tmdbId: 603,
        isEpisode: false,
        season: 0,
        episode: 0,
        qualityValue: 720,
        stamp: 1700000000000,
      );
      final second = DownloadValidation.videoFileName(
        title: 'The Matrix',
        tmdbId: 603,
        isEpisode: false,
        season: 0,
        episode: 0,
        qualityValue: 720,
        stamp: 1700000000001,
      );

      expect(first, 'the_matrix_603_720p_1700000000000.mp4');
      expect(second, isNot(first));
    });

    test('keeps movie and episode files distinct', () {
      final episode = DownloadValidation.videoFileName(
        title: 'Breaking Bad',
        tmdbId: 1396,
        isEpisode: true,
        season: 5,
        episode: 1,
        qualityValue: 1080,
        stamp: 1,
      );
      expect(episode, 'breaking_bad_1396_s5e1_1080p_1.mp4');
    });

    test('supports provider-backed negative ids without a leading dash', () {
      final name = DownloadValidation.videoFileName(
        title: 'Short',
        tmdbId: -12345,
        isEpisode: false,
        season: 0,
        episode: 0,
        qualityValue: 480,
        stamp: 9,
      );
      expect(name, contains('p12345'));
      expect(name, isNot(contains('--')));
    });

    test('safeName blocks traversal and empty names', () {
      expect(DownloadValidation.safeName('../../etc/passwd'), 'etc_passwd');
      expect(DownloadValidation.safeName('!!!'), 'title');
      expect(
        DownloadValidation.safeName('A very long title '.padRight(120, 'x')),
        hasLength(48),
      );
    });

    test('builds subtitle file names from the video stem', () {
      final name = DownloadValidation.subtitleFileName(
        videoPath: '/data/Flix/the_matrix_603_720p_1.mp4',
        language: 'en',
        extension: 'srt',
      );
      expect(name, 'the_matrix_603_720p_1.en.srt');
    });

    test('derives file stems from both path separators', () {
      expect(DownloadValidation.fileStem('/a/b/movie.mp4'), 'movie');
      expect(DownloadValidation.fileStem(r'C:\a\b\movie.mp4'), 'movie');
      expect(DownloadValidation.fileStem('movie'), 'movie');
    });

    test('detects subtitle formats from URL and content', () {
      expect(
        DownloadValidation.subtitleExtension(
          'https://x/a.srt',
          '1\n00:00:01,000 --> 00:00:02,000\nHi',
        ),
        'srt',
      );
      expect(
        DownloadValidation.subtitleExtension('https://x/a.vtt', 'WEBVTT'),
        'vtt',
      );
      expect(
        DownloadValidation.subtitleExtension('https://x/a', 'WEBVTT\n\n'),
        'vtt',
      );
    });
  });

  group('DownloadValidation integrity', () {
    test('detects HTML and XML error pages', () {
      expect(DownloadValidation.looksLikeMarkup('<!DOCTYPE html><html>'), isTrue);
      expect(DownloadValidation.looksLikeMarkup('  <html><body>403'), isTrue);
      expect(DownloadValidation.looksLikeMarkup('<?xml version="1.0"?>'), isTrue);
      expect(
        DownloadValidation.looksLikeMarkup(
          '1\n00:00:01,000 --> 00:00:02,000\nHello',
        ),
        isFalse,
      );
      expect(DownloadValidation.looksLikeMarkup('fake video bytes'), isFalse);
    });

    test('only allows deletions inside the managed directory', () {
      const directory = '/data/user/0/com.halluyapp.flix/files/Flix';
      expect(
        DownloadValidation.isWithinDirectory(
          '/data/user/0/com.halluyapp.flix/files/Flix/movie.mp4',
          directory,
        ),
        isTrue,
      );
      expect(
        DownloadValidation.isWithinDirectory(
          '/data/user/0/com.halluyapp.flix/files/Other/movie.mp4',
          directory,
        ),
        isFalse,
      );
      expect(
        DownloadValidation.isWithinDirectory(
          '/data/user/0/com.halluyapp.flix/files/Flix/../secret.mp4',
          directory,
        ),
        isFalse,
      );
    });

    test('explains DownloadManager failures in plain language', () {
      expect(DownloadValidation.failureMessage(1007), contains('storage'));
      expect(DownloadValidation.failureMessage(403), contains('refused'));
      expect(DownloadValidation.failureMessage(404), contains('no longer'));
      expect(DownloadValidation.failureMessage(1004), contains('connection'));
      expect(DownloadValidation.failureMessage(null), isNotEmpty);
    });

    test('does not claim pause/resume support', () {
      expect(DownloadValidation.supportsPauseResume, isFalse);
    });
  });
}
