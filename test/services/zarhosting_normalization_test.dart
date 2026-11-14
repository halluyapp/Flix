import 'package:flutter_test/flutter_test.dart';
import 'package:flix/services/zarhosting_service.dart';

void main() {
  group('ZarhostingService Normalization Tests', () {
    test('normalizes title by removing punctuation and special characters', () {
      expect(ZarhostingService.normalizeTitle('Squid Game: The Challenge (2023)'), 'squid game the challenge 2023');
      expect(ZarhostingService.normalizeTitle("Grey's Anatomy!"), 'greys anatomy');
      expect(ZarhostingService.normalizeTitle('K-Drama: Crash Landing On You'), 'kdrama crash landing on you');
    });

    test('calculates accurate word similarity between query and candidate', () {
      final exact = ZarhostingService.calculateSimilarity('Squid Game', 'Squid Game');
      expect(exact, 1.0);

      final subtitle = ZarhostingService.calculateSimilarity('Squid Game', 'Squid Game Season 2');
      expect(subtitle, greaterThanOrEqualTo(0.8));

      final completelyDifferent = ZarhostingService.calculateSimilarity('Inception', 'Frozen');
      expect(completelyDifferent, 0.0);
    });
  });
}
