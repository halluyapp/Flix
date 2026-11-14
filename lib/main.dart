import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/theme/flix_theme.dart';
import 'services/download_service.dart';
import 'services/user_state_service.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint(
        'Flix uncaught Flutter error: ${details.exception}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    debugPrint('Flix uncaught platform error: $error\n$stackTrace');
    return false;
  };
  try {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  } catch (error, stackTrace) {
    debugPrint('Flix startup: orientation setup failed: $error\n$stackTrace');
  }

  final userState = UserStateService();
  try {
    await userState.init();
  } catch (error, stackTrace) {
    debugPrint(
        'Flix startup: saved profile state could not be restored: $error\n$stackTrace');
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
