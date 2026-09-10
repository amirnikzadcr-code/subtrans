import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const SubTransApp());
}

/// Visual identity copied from the original "Video Translate" app
/// (extracted from its APK): YouTube-red accent, near-black surfaces,
/// Inter Display for Latin + IBM Plex Sans Arabic for Persian text.
class SubTransApp extends StatelessWidget {
  const SubTransApp({super.key});

  static const brandRed = Color(0xFFE62117);

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: brandRed,
      brightness: Brightness.dark,
      surface: const Color(0xFF0F0F0F),
    ).copyWith(
      primary: brandRed,
      primaryContainer: const Color(0xFF3A0B08),
      secondary: const Color(0xFFFF6E63),
      surfaceContainerHighest: const Color(0xFF1D1C1E),
    );
    return MaterialApp(
      title: 'SubTrans',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: brandRed),
        fontFamily: 'SubSans',
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        fontFamily: 'SubSans',
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: Color(0xFF0F0F0F),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1D1C1E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: brandRed,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF2C2B2E),
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'SubSans'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFF1B1A1D),
          modalBackgroundColor: Color(0xFF1B1A1D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF151417),
          indicatorColor: brandRed.withAlpha(46),
        ),
      ),
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeScreen(),
    );
  }
}
