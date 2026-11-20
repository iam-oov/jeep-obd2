import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/user_app_spec.dart';
import '../ui/devices_screen.dart';

UserAppSpec buildUserApp() {
  const seed = Color(0xFF4B5320);
  return UserAppSpec(
    title: 'Jeep OBD2',
    theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
    darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
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
