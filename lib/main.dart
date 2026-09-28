import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const AmanPlayerApp());
}

class AmanPlayerApp extends StatelessWidget {
  const AmanPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF16B7A7);
    final light = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: const Color(0xFFF7F8FA),
    );
    final dark = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: const Color(0xFF101315),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'أمان بلاير',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: light,
        useMaterial3: true,
        cardTheme: const CardThemeData(elevation: 0),
      ),
      darkTheme: ThemeData(
        colorScheme: dark,
        useMaterial3: true,
        cardTheme: const CardThemeData(elevation: 0),
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: HomePage(),
      ),
    );
  }
}
