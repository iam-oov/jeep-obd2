import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'ui/devices_screen.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()
        ..loadDescriptions()
        ..loadVehicle(),
      child: const JeepObdApp(),
    ),
  );
}

class JeepObdApp extends StatelessWidget {
  const JeepObdApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4B5320); // verde olivo
    return MaterialApp(
      title: 'Jeep OBD2',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const DevicesScreen(),
    );
  }
}
