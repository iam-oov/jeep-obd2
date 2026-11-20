import 'package:flutter/widgets.dart';

import 'core/core_shell.dart';
import 'features/user_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(CoreShell(spec: buildUserApp()));
}
