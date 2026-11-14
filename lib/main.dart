import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/theme/flix_theme.dart';
import 'services/user_state_service.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  } catch (error, stackTrace) {
    debugPrint('Flix startup: orientation setup failed: $error\n$stackTrace');
  }

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
      theme: FlixTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
