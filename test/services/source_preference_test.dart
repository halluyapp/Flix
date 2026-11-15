import 'package:flutter_test/flutter_test.dart';

import 'package:flix/models/stream_source.dart';
import 'package:flix/services/source_preference.dart';

StreamSource _source({
  required int quality,
  StreamFormat format = StreamFormat.mp4,
}) =>
    StreamSource(
      url: 'https://media.example.com/movie-$quality-${format.name}.mp4',
      resolution: '${quality}p',
      qualityValue: quality,
      format: format.name.toUpperCase(),
      formatKind: format,
      sizeBytes: quality * 1000000,
      durationSeconds: 5000,
      isPreview: false,
      verifiedFullLength: true,
    );

List<StreamSource> _sources() => [
      _source(quality: 2160),
      _source(quality: 1080),
      _source(quality: 1080, format: StreamFormat.dash),
      _source(quality: 720),
      _source(quality: 480),
    ];

void main() {
  test('a normal device starts with the best file', () {
    final sources = _sources();
    expect(preferredSource(sources, maxQuality: 0), same(sources.first));
  });

  test('a low-memory device starts at or below its cap', () {
    final sources = _sources();
    final chosen = preferredSource(sources, maxQuality: 480);
    expect(chosen!.qualityValue, 480);
  });

  test('falls back to the smallest file when nothing is under the cap', () {
    final sources = [_source(quality: 2160), _source(quality: 1080)];
    final chosen = preferredSource(sources, maxQuality: 480);
    expect(chosen!.qualityValue, 1080);
  });

  test('candidates try the preferred source first, then smallest upwards', () {
    final candidates = playbackCandidates(_sources(), maxQuality: 480);

    expect(candidates.first.qualityValue, 480);
    final rest = candidates.skip(1).map((source) => source.qualityValue).toList();
    expect(rest, [720, 1080, 1080, 2160]);
  });

  test('a plain MP4 is tried before DASH at the same quality', () {
    final candidates = playbackCandidates(_sources(), maxQuality: 480);
    final at1080 = candidates.where((source) => source.qualityValue == 1080);
    expect(at1080.first.formatKind, StreamFormat.mp4);
    expect(at1080.last.formatKind, StreamFormat.dash);
  });

  test('candidates are capped so a dead title cannot loop forever', () {
    final many = [for (var i = 1; i <= 10; i++) _source(quality: i * 240)];
    expect(playbackCandidates(many, maxQuality: 0), hasLength(6));
  });
}
