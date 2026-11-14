import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class FlixTheme {
  static const Color background = Color(0xFF141414);
  static const Color surface = Color(0xFF1F1F1F);
  static const Color surfaceElevation2 = Color(0xFF2B2B2B);
  static const Color red = Color(0xFFE50914);
  static const Color white = Color(0xFFFFFFFF);
  static const Color grey = Color(0xFFA3A3A3);
  static const Color darkGrey = Color(0xFF4A4A4A);
  static const Color matchGreen = Color(0xFF46D369);

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: red,
      colorScheme: const ColorScheme.dark(
        primary: red,
        secondary: white,
        surface: surface,
      ),
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme).copyWith(
        displayLarge: GoogleFonts.bebasNeue(
          color: white,
          fontSize: 36,
          letterSpacing: 1.2,
        ),
        displayMedium: GoogleFonts.bebasNeue(
          color: white,
          fontSize: 28,
          letterSpacing: 1.0,
        ),
        titleLarge: const TextStyle(
          color: white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        bodyLarge: const TextStyle(
          color: white,
          fontSize: 14,
        ),
        bodyMedium: const TextStyle(
          color: grey,
          fontSize: 12,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF121212),
        selectedItemColor: white,
        unselectedItemColor: grey,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 10),
      ),
    );
  }
}
