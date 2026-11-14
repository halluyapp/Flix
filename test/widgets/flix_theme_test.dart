import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flix/core/theme/flix_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlixTheme system tests', () {
    test('provides Flix brand colors and a dark theme', () {
      expect(FlixTheme.red, const Color(0xFFE50914));
      expect(FlixTheme.background, const Color(0xFF141414));

      final theme = FlixTheme.darkTheme;
      expect(theme.scaffoldBackgroundColor, FlixTheme.background);
      expect(theme.primaryColor, FlixTheme.red);
    });
  });
}
