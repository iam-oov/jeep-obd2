import 'package:flutter/widgets.dart';

import 'auth/brain_session.dart';

class CoreScope extends InheritedNotifier<BrainSession> {
  const CoreScope({super.key, required BrainSession session, required super.child}) : super(notifier: session);

  static BrainSession of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CoreScope>()!.notifier!;
}
