import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../l10n/strings.dart';
import 'flow_screen.dart';
import 'info_screens.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final MigrationController controller;

  void _open(BuildContext context, String role) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FlowScreen(controller: controller, role: role)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(S.t('app_title'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _RoleCard(
              icon: Icons.upload_rounded,
              title: S.t('send'),
              subtitle: S.t('send_sub'),
              onTap: () => _open(context, 'sender'),
            ),
            const SizedBox(height: 16),
            _RoleCard(
              icon: Icons.download_rounded,
              title: S.t('receive'),
              subtitle: S.t('receive_sub'),
              onTap: () => _open(context, 'receiver'),
            ),
            const SizedBox(height: 24),
            Row(children: [
              Icon(Icons.wifi_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(child: Text(S.t('same_wifi'), style: theme.textTheme.bodyMedium)),
            ]),
            const SizedBox(height: 24),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(S.t('what_moves')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CapabilityInfoScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: Text(S.t('history')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => HistoryScreen(db: controller.db))),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.primaryContainer,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(children: [
            Icon(icon, size: 40, color: cs.onPrimaryContainer),
            const SizedBox(width: 20),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.onPrimaryContainer)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(color: cs.onPrimaryContainer)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
