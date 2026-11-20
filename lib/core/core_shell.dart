import 'package:flutter/material.dart';

import 'auth/brain_session.dart';
import 'auth/identity_provider.dart';
import 'core_scope.dart';
import 'mailbox/cerebro_client.dart';
import 'mailbox/mailbox_screen.dart';
import 'sign_in_screen.dart';
import 'user_app_spec.dart';
import 'widgets.dart';

class CoreShell extends StatefulWidget {
  const CoreShell({super.key, required this.spec, this.session});

  final UserAppSpec spec;
  final BrainSession? session;

  @override
  State<CoreShell> createState() => _CoreShellState();
}

class _CoreShellState extends State<CoreShell> {
  final _navigator = GlobalKey<NavigatorState>();
  late final BrainSession _session =
      widget.session ?? BrainSession(client: CerebroClient(), identity: GoogleIdentityProvider());

  @override
  void initState() {
    super.initState();
    _session.restore();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    return CoreScope(
      session: _session,
      child: spec.wrap(
        MaterialApp(
          navigatorKey: _navigator,
          title: spec.title,
          debugShowCheckedModeBanner: false,
          theme: spec.theme,
          darkTheme: spec.darkTheme,
          home: _AuthGate(title: spec.title, child: spec.home),
          builder: (context, child) => _CoreFrame(navigator: _navigator, child: child!),
        ),
      ),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return switch (CoreScope.of(context).status) {
      SessionStatus.signedIn => child,
      SessionStatus.signedOut => SignInScreen(title: title),
      SessionStatus.loading => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: ListView(children: const [CoreProgressCard(text: 'Entrando…')]),
        ),
    };
  }
}

class _CoreFrame extends StatelessWidget {
  const _CoreFrame({required this.navigator, required this.child});

  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final signedIn = CoreScope.of(context).status == SessionStatus.signedIn;
    final inset = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        child,
        if (signedIn)
          Positioned(
            left: 16 + inset.left,
            bottom: 16 + inset.bottom,
            child: Semantics(
              label: 'Sugerencias',
              button: true,
              child: FloatingActionButton.small(
                key: const Key('core-suggestions'),
                heroTag: null,
                onPressed: () => navigator.currentState?.push(
                  MaterialPageRoute<void>(builder: (_) => const MailboxScreen()),
                ),
                child: const Icon(Icons.lightbulb_outline),
              ),
            ),
          ),
      ],
    );
  }
}
