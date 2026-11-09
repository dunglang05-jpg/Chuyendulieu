import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/domain/categories.dart';
import '../data/db.dart';
import '../l10n/strings.dart';
import 'clay.dart';
import 'flow_screen.dart' show exportLogButton;

String statusLabel(SupportStatus s) => switch (s) {
      SupportStatus.supported => 'Hỗ trợ',
      SupportStatus.permissionRequired => 'Cần quyền',
      SupportStatus.officialFlow => 'Qua ứng dụng hệ thống',
      SupportStatus.partial => 'Một phần',
      SupportStatus.unsupported => 'Không hỗ trợ',
      SupportStatus.oemAuthorized => 'Cần quyền nhà sản xuất',
    };

Color _statusColor(SupportStatus s) => switch (s) {
      SupportStatus.supported => Clay.accent,
      SupportStatus.permissionRequired || SupportStatus.officialFlow || SupportStatus.partial => Clay.warn,
      SupportStatus.unsupported || SupportStatus.oemAuthorized => Clay.danger,
    };

IconData _categoryIcon(String id) => switch (id) {
      'photos' => Icons.image_outlined,
      'videos' => Icons.videocam_outlined,
      'contacts' => Icons.person_outline_rounded,
      'documents' => Icons.description_outlined,
      'audio' => Icons.music_note_outlined,
      'calendar' => Icons.event_outlined,
      _ => Icons.folder_outlined,
    };

/// Small status pill: colour + text (never colour alone).
class _Pill extends StatelessWidget {
  const _Pill(this.label, this.status);
  final String label;
  final SupportStatus status;
  @override
  Widget build(BuildContext context) {
    final c = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Text('$label: ${statusLabel(status)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c)),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 26, 4, 12),
        child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      );
}

/// Explains, before any transfer, what moves, what needs official app flows, and what never moves.
class CapabilityInfoScreen extends StatelessWidget {
  const CapabilityInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.t('what_moves'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 32), children: [
        for (final c in categoryRegistry) ...[
          ClaySurface(
            radius: 26,
            depth: 6,
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                ClayBlob(icon: _categoryIcon(c.id), size: 44, pressed: true),
                const SizedBox(width: 14),
                Expanded(child: Text(c.titleVi, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 14),
              for (final (name, ps) in [('Android', c.android), ('iPhone', c.ios)]) ...[
                Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Clay.sub)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 6, children: [_Pill('Gửi', ps.export), _Pill('Nhận', ps.import)]),
                const SizedBox(height: 6),
                Text(ps.note, style: const TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w500)),
                const SizedBox(height: 12),
              ],
            ]),
          ),
          const SizedBox(height: 16),
        ],
        _Section(S.t('not_transferable')),
        ClayInset(
          radius: 24,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Column(children: [
            for (final (title, why) in notTransferable)
              ListTile(
                leading: const Icon(Icons.block_rounded, color: Clay.danger),
                title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(why, style: const TextStyle(color: Clay.sub)),
              ),
          ]),
        ),
        _Section(S.t('official_flows')),
        for (final e in officialAppFlows.entries) ...[
          ClaySurface(
            radius: 22,
            depth: 5,
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.chat_bubble_outline_rounded, color: Clay.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.key, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(e.value, style: const TextStyle(fontSize: 13, height: 1.4, color: Clay.sub)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 14),
        ],
      ]),
    );
  }
}

String _stateLabel(Object? s) => switch (s) {
      'completed' => 'Hoàn tất',
      'partial' => 'Hoàn tất một phần',
      'cancelled' => 'Đã hủy',
      'failed' => 'Thất bại',
      _ => '$s',
    };

Color _stateColor(Object? s) => switch (s) {
      'completed' => Clay.accent,
      'partial' => Clay.warn,
      _ => Clay.danger,
    };

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.db, this.controller});
  final AppDatabase db;

  /// When given, the screen offers "Xuất log chẩn đoán" (device test: users looked for it here).
  final MigrationController? controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.t('history'))),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: db.history(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          final rows = snap.data ?? const [];
          final c = controller;
          if (rows.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const ClayBlob(icon: Icons.history_rounded, size: 72, pressed: true),
                const SizedBox(height: 16),
                Text(S.t('history_empty'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Clay.sub)),
                if (c != null) ...[const SizedBox(height: 16), exportLogButton(context, c)],
              ]),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            itemCount: rows.length + (c == null ? 0 : 1),
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (_, i) {
              if (i == rows.length) return Center(child: exportLogButton(context, c!));
              final r = rows[i];
              final when = DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int);
              final mb = ((r['bytes'] as int? ?? 0) / 1e6).toStringAsFixed(1);
              String two(int n) => n.toString().padLeft(2, '0');
              final date = '${two(when.day)}/${two(when.month)}/${when.year} ${two(when.hour)}:${two(when.minute)}';
              final sender = r['role'] == 'sender';
              final peer = r['peer_platform'] == 'ios' ? 'iPhone' : (r['peer_platform'] == 'android' ? 'Android' : '');
              return ClaySurface(
                radius: 24,
                depth: 6,
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  ClayBlob(icon: sender ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 46, pressed: true),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${sender ? S.t('cont_role_sender') : S.t('cont_role_receiver')}${peer.isEmpty ? '' : ' · $peer'}',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('$date · $mb MB', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Clay.sub)),
                      const SizedBox(height: 4),
                      Text('${r['files_ok']} ${S.t('stat_ok').toLowerCase()} · ${r['files_failed']} ${S.t('stat_failed').toLowerCase()}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: _stateColor(r['state']).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                    child: Text(_stateLabel(r['state']),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _stateColor(r['state']))),
                  ),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}
