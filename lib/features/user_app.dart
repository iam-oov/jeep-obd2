import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/user_app_spec.dart';
import '../ui/devices_screen.dart';

UserAppSpec buildUserApp() {
  final theme = buildWhiteTheme();
  return UserAppSpec(
    title: 'Jeep OBD2',
    theme: theme,
    darkTheme: theme,
    home: const DevicesScreen(),
    wrap: (app) => ChangeNotifierProvider(
      create: (_) => AppState()
        ..loadDescriptions()
        ..loadVehicle()
        ..loadApiKeys(),
      child: app,
    ),
  );
}

ThemeData buildWhiteTheme() {
  const seed = Color(0xFF9E9E9E);
  final scheme = ColorScheme.fromSeed(seedColor: seed).copyWith(
    surface: Colors.white,
    onSurface: const Color(0xFF212121),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Color(0xFF212121),
      surfaceTintColor: Colors.white,
    ),
  );
}
