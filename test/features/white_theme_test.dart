import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/features/user_app.dart';

void main() {
  test('el tema usa tonos blancos y es claro', () {
    final theme = buildWhiteTheme();
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, Colors.white);
    expect(theme.colorScheme.surface, Colors.white);
    expect(theme.appBarTheme.backgroundColor, Colors.white);
  });
}
