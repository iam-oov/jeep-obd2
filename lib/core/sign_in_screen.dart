import 'package:flutter/material.dart';

import 'core_scope.dart';

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final session = CoreScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Entra con tu cuenta de Google para usar la app.', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('Con tu cuenta puedes pedir mejoras y descargar tu versión más reciente.'),
          if (session.error != null) ...[
            const SizedBox(height: 16),
            Text(session.error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('core-sign-in'),
            onPressed: session.signIn,
            icon: const Icon(Icons.login),
            label: const Text('Entrar con Google'),
          ),
        ],
      ),
    );
  }
}
