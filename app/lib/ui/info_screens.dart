import 'package:flutter/material.dart';

import '../core/domain/categories.dart';
import '../data/db.dart';
import '../l10n/strings.dart';

String statusLabel(SupportStatus s) => switch (s) {
      SupportStatus.supported => 'Hỗ trợ',
      SupportStatus.permissionRequired => 'Cần quyền',
      SupportStatus.officialFlow => 'Qua ứng dụng hệ thống',
      SupportStatus.partial => 'Một phần',
      SupportStatus.unsupported => 'Không hỗ trợ',
      SupportStatus.oemAuthorized => 'Cần quyền nhà sản xuất',
    };

/// Explains, before any transfer, what moves, what needs official app flows, and what never moves.
class CapabilityInfoScreen extends StatelessWidget {
  const CapabilityInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(S.t('what_moves'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final c in categoryRegistry)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.titleVi, style: tt.titleMedium),
                const SizedBox(height: 6),
                Text('Android: gửi ${statusLabel(c.android.export)} · nhận ${statusLabel(c.android.import)}'),
                Text(c.android.note, style: tt.bodySmall),
                const SizedBox(height: 6),
                Text('iPhone: gửi ${statusLabel(c.ios.export)} · nhận ${statusLabel(c.ios.import)}'),
                Text(c.ios.note, style: tt.bodySmall),
              ]),
            ),
          ),
        const SizedBox(height: 16),
        Text(S.t('not_transferable'), style: tt.titleMedium),
        for (final (title, why) in notTransferable)
          ListTile(leading: const Icon(Icons.block_rounded), title: Text(title), subtitle: Text(why)),
        const SizedBox(height: 16),
        Text(S.t('official_flows'), style: tt.titleMedium),
        for (final e in officialAppFlows.entries)
          ListTile(leading: const Icon(Icons.chat_bubble_outline_rounded), title: Text(e.key), subtitle: Text(e.value)),
      ]),
    );
  }
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.db});
  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.t('history'))),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: db.history(),
        builder: (context, snap) {
          final rows = snap.data ?? const [];
          if (rows.isEmpty) return const Center(child: Text('—'));
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = rows[i];
              final when = DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int);
              final mb = ((r['bytes'] as int? ?? 0) / 1e6).toStringAsFixed(1);
              return ListTile(
                leading: Icon(r['role'] == 'sender' ? Icons.upload_rounded : Icons.download_rounded),
                title: Text('${r['state']} · ${r['files_ok']} OK · ${r['files_failed']} lỗi'),
                subtitle: Text('$when · $mb MB · ${r['peer_platform'] ?? ''}'),
              );
            },
          );
        },
      ),
    );
  }
}
