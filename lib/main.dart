import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'routes/app_routes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.instance.initialize();
  if (!kIsWeb) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
  runApp(const SaatDinApp());
}

class SaatDinApp extends StatelessWidget {
  const SaatDinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'SaatDin',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeController.instance.themeMode,
          initialRoute: AppRoutes.onboarding,
          routes: AppRoutes.routes,
        );
      },
    );
  }
}
