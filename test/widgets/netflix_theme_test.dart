import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flix/core/theme/netflix_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NetflixTheme System Tests', () {
    test('provides exact Netflix brand colors and dark theme', () {
      expect(NetflixTheme.netflixRed, const Color(0xFFE50914));
      expect(NetflixTheme.netflixBlack, const Color(0xFF141414));

      final theme = NetflixTheme.darkTheme;
      expect(theme.scaffoldBackgroundColor, NetflixTheme.netflixBlack);
      expect(theme.primaryColor, NetflixTheme.netflixRed);
    });
  });
}
