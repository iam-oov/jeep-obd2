import 'package:flutter/material.dart';

class UserAppSpec {
  const UserAppSpec({
    required this.title,
    required this.theme,
    required this.darkTheme,
    required this.home,
    this.wrap = _identity,
  });

  final String title;
  final ThemeData theme;
  final ThemeData darkTheme;
  final Widget home;

  final Widget Function(Widget app) wrap;

  static Widget _identity(Widget app) => app;
}
