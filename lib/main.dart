import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/theme/netflix_theme.dart';
import 'services/user_state_service.dart';
import 'screens/splash_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => UserStateService()),
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
      theme: NetflixTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
