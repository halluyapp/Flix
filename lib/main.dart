import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/theme/flix_theme.dart';
import 'screens/splash_screen.dart';
import 'services/diagnostics_service.dart';
import 'services/download_service.dart';
import 'services/user_state_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Captures framework and uncaught asynchronous errors into a small, local,
  // sanitized diagnostic log. Nothing is uploaded automatically.
  DiagnosticsService.instance.install();

  try {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  } catch (error) {
    DiagnosticsService.instance.record(
      scope: 'startup',
      operation: 'orientation',
      error: error,
    );
  }

  final userState = UserStateService();
  try {
    await userState.init();
  } catch (error) {
    DiagnosticsService.instance.record(
      scope: 'startup',
      operation: 'restore_profile_state',
      error: error,
    );
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: userState),
        ChangeNotifierProvider<DownloadService>(
          create: (_) {
            final service = DownloadService();
            unawaited(service.init());
            return service;
          },
        ),
      ],
      child: const FlixApp(),
    ),
  );
}

class FlixApp extends StatelessWidget {
  const FlixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flix',
      debugShowCheckedModeBanner: false,
      theme: FlixTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
