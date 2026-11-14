import 'package:flutter_test/flutter_test.dart';
import 'package:flix/models/stream_source.dart';

void main() {
  group('StreamSource Model Tests', () {
    test('parses full-length MP4 source with int fields correctly', () {
      final json = {
        'url': 'https://cdn.example.com/movie_1080p.mp4',
        'resolution': '1080p',
        'quality': 1080,
        'format': 'MP4',
        'duration': 7200,
        'size_bytes': 2147483648,
        'source_label': 'Main Direct',
      };

      final source = StreamSource.fromJson(json);

      expect(source.url, 'https://cdn.example.com/movie_1080p.mp4');
      expect(source.resolution, '1080p');
      expect(source.qualityValue, 1080);
      expect(source.format, 'MP4');
      expect(source.durationSeconds, 7200);
      expect(source.isPreview, false);
      expect(source.verifiedFullLength, true);
    });

    test('parses String duration/size fields safely without type crash', () {
      final json = {
        'playback_url': 'https://cdn.example.com/stream.m3u8',
        'label': '720p',
        'duration_sec': '5400',
        'size': '104857600',
      };

      final source = StreamSource.fromJson(json);

      expect(source.url, 'https://cdn.example.com/stream.m3u8');
      expect(source.qualityValue, 720);
      expect(source.format, 'HLS');
      expect(source.durationSeconds, 5400);
      expect(source.sizeBytes, 104857600);
      expect(source.isPreview, false);
      expect(source.verifiedFullLength, true);
    });

    test('classifies short duration or preview label as isPreview = true', () {
      final trailerJson = {
        'file': 'https://cdn.example.com/trailer.mp4',
        'quality': '480p',
        'duration': 120,
        'source_label': 'Official Preview Clip',
      };

      final source = StreamSource.fromJson(trailerJson);

      expect(source.isPreview, true);
      expect(source.verifiedFullLength, null);
    });
  });
}
