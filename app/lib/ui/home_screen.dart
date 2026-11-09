import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../l10n/strings.dart';
import 'clay.dart';
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
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
          children: [
            Row(children: [
              const ClayBlob(icon: Icons.swap_vert_rounded, size: 42, filled: true),
              const SizedBox(width: 12),
              Text(S.t('app_title'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 26),
            Text(S.t('home_question'),
                style: const TextStyle(fontSize: 30, height: 1.18, fontWeight: FontWeight.w700, letterSpacing: -0.4)),
            const SizedBox(height: 8),
            Text(S.t('home_sub'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Clay.sub)),
            for (final r in controller.pendingContinuations.take(1)) ...[
              const SizedBox(height: 20),
              ClaySurface(
                radius: 24,
                depth: 6,
                padding: const EdgeInsets.all(16),
                onTap: () => _open(context, r.role),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const ClayBlob(icon: Icons.restore_rounded, size: 42, filled: true),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(S.t('cont_banner_title'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        S.t('cont_banner_body', {
                          'role': S.t('cont_role_${r.role}'),
                          'name': r.peerName,
                          'time': '${r.createdAt.toLocal().hour.toString().padLeft(2, '0')}:'
                              '${r.createdAt.toLocal().minute.toString().padLeft(2, '0')}',
                          'action': S.t(r.role == 'sender' ? 'send' : 'receive'),
                        }),
                        style: const TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600, color: Clay.sub),
                      ),
                    ]),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 28),
            _RoleButton(
              filled: true,
              icon: Icons.arrow_upward_rounded,
              title: S.t('send'),
              subtitle: S.t('send_sub'),
              onTap: () => _open(context, 'sender'),
            ),
            const SizedBox(height: 22),
            _RoleButton(
              filled: false,
              icon: Icons.arrow_downward_rounded,
              title: S.t('receive'),
              subtitle: S.t('receive_sub'),
              onTap: () => _open(context, 'receiver'),
            ),
            const SizedBox(height: 26),
            Row(children: [
              Expanded(
                child: _SmallTile(
                  icon: Icons.info_outline_rounded,
                  label: S.t('what_moves'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CapabilityInfoScreen())),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _SmallTile(
                  icon: Icons.history_rounded,
                  label: S.t('history'),
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => HistoryScreen(db: controller.db, controller: controller))),
                ),
              ),
            ]),
            const SizedBox(height: 30),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.lock_outline_rounded, size: 14, color: Clay.sub),
              const SizedBox(width: 6),
              Flexible(
                child: Text(S.t('home_footer'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Clay.sub)),
              ),
            ]),
            const SizedBox(height: 4),
            Center(child: exportLogButton(context, controller)),
          ],
        ),
        ),
      ),
    );
  }
}

class _RoleButton extends StatelessWidget {
  const _RoleButton({required this.filled, required this.icon, required this.title, required this.subtitle, required this.onTap});
  final bool filled;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(30);
    final fg = filled ? Colors.white : Clay.fg;
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Clay.bg,
          gradient: filled ? Clay.gradient : null,
          borderRadius: r,
          boxShadow: filled ? Clay.puff() : Clay.raised(),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: r,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Row(children: [
                if (filled)
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
                    child: Icon(icon, color: Colors.white, size: 28),
                  )
                else
                  ClayBlob(icon: icon, size: 56, pressed: true),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: fg)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: filled ? Colors.white.withValues(alpha: 0.85) : Clay.sub)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallTile extends StatelessWidget {
  const _SmallTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ClaySurface(
        radius: 24,
        depth: 6,
        padding: const EdgeInsets.all(16),
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: Clay.accent, size: 22),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        ]),
      );
}
