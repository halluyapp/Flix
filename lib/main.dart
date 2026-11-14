import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/theme/netflix_theme.dart';
import 'services/user_state_service.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  final userState = UserStateService();
  await userState.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: userState),
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
