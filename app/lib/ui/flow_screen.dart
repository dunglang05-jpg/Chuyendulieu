import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ptp_platform/ptp_platform.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/controller.dart';
import '../core/domain/categories.dart';
import '../core/domain/state_machine.dart';
import '../core/protocol/errors.dart';
import '../l10n/strings.dart';
import 'info_screens.dart';

String fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

String errorText(PtpException e) => switch (e.code) {
      PtpErrorCode.pairingExpired => S.t('err_qr_expired'),
      PtpErrorCode.peerTimeout || PtpErrorCode.networkInterrupted => S.t('err_connect'),
      PtpErrorCode.authenticationFailed => S.t('err_auth'),
      PtpErrorCode.protocolVersionMismatch => S.t('err_version'),
      PtpErrorCode.storageInsufficient => S.t('err_storage'),
      PtpErrorCode.permissionDenied => S.t('err_permission'),
      PtpErrorCode.hashMismatch => S.t('err_hash'),
      PtpErrorCode.userCancelled => S.t('err_cancelled'),
      _ => '${S.t('err_internal')} (${e.code.wire})',
    };

/// One screen that renders the current step of the migration state machine.
class FlowScreen extends StatefulWidget {
  const FlowScreen({super.key, required this.controller, required this.role});
  final MigrationController controller;
  final String role;

  @override
  State<FlowScreen> createState() => _FlowScreenState();
}

class _FlowScreenState extends State<FlowScreen> {
  bool _scanning = false;
  MigrationController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.backToHome();
  }

  Future<bool> _confirmLeave() async {
    if (c.state == MigrationState.idle || c.state.isTerminal) return true;
    await c.cancel();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: c.state == MigrationState.idle || c.state.isTerminal,
      onPopInvoked: (didPop) async {
        if (!didPop && await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.role == 'sender' ? S.t('send') : S.t('receive'))),
        body: SafeArea(
          child: AnimatedBuilder(
            animation: c,
            builder: (context, _) => Padding(padding: const EdgeInsets.all(16), child: _body(context)),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (c.pendingSas != null) return _ConfirmView(c: c);
    if (c.pendingManifest != null) return _ApproveView(c: c);
    if (c.reconnecting) return _TransferView(c: c);
    switch (c.state) {
      case MigrationState.idle:
        return _scanning ? _ScanView(onCode: (code) {
                setState(() => _scanning = false);
                c.joinQr(code);
              }) : _ConnectChoice(role: widget.role, onShow: () => c.showQr(widget.role), onScan: () => setState(() => _scanning = true));
      case MigrationState.discovering:
      case MigrationState.pairing:
        return c.qrUri != null ? _QrView(c: c, role: widget.role) : const Center(child: CircularProgressIndicator());
      case MigrationState.authenticating:
      case MigrationState.capabilityExchange:
      case MigrationState.scanning:
        return Center(child: Text(S.t('preparing')));
      case MigrationState.preview:
        return _SelectView(c: c);
      case MigrationState.preparing:
        return c.role == 'receiver'
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(S.t('waiting_sender')),
              ]))
            : Center(child: Text(S.t('preparing')));
      case MigrationState.transferring:
      case MigrationState.verifying:
      case MigrationState.importing:
        return _TransferView(c: c);
      case MigrationState.completed:
      case MigrationState.partial:
      case MigrationState.failed:
      case MigrationState.cancelled:
        return _ReportView(c: c);
    }
  }
}

class _ConnectChoice extends StatelessWidget {
  const _ConnectChoice({required this.role, required this.onShow, required this.onScan});
  final String role;
  final VoidCallback onShow;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    // Default: the new phone (receiver) shows the code, the old phone scans. Either way works.
    final showFirst = role == 'receiver';
    final show = FilledButton.icon(onPressed: onShow, icon: const Icon(Icons.qr_code_2_rounded), label: Text(S.t('show_qr')));
    final scan = OutlinedButton.icon(onPressed: onScan, icon: const Icon(Icons.qr_code_scanner_rounded), label: Text(S.t('scan_qr')));
    return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(S.t('same_wifi'), textAlign: TextAlign.center),
      const SizedBox(height: 32),
      showFirst ? show : scan,
      const SizedBox(height: 12),
      showFirst ? scan : show,
    ]);
  }
}

class _QrView extends StatefulWidget {
  const _QrView({required this.c, required this.role});
  final MigrationController c;
  final String role;
  @override
  State<_QrView> createState() => _QrViewState();
}

class _QrViewState extends State<_QrView> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.c.qrExpires?.difference(DateTime.now()).inSeconds ?? 0;
    final eps = widget.c.qrEndpoints;
    final loopbackOnly = eps.isNotEmpty && eps.every((e) => e.startsWith('127.'));
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Text(S.t('qr_hint'), textAlign: TextAlign.center),
      const SizedBox(height: 16),
      Container(
        color: Colors.white,
        padding: const EdgeInsets.all(12),
        child: QrImageView(data: widget.c.qrUri!, size: 260, semanticsLabel: 'QR'),
      ),
      const SizedBox(height: 12),
      if (left > 0)
        Text(S.t('qr_expires', {'s': left}))
      else
        FilledButton(onPressed: () => widget.c.showQr(widget.role), child: Text(S.t('qr_new'))),
      if (loopbackOnly) ...[
        const SizedBox(height: 12),
        Text(S.t('no_wifi_ip'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    ]);
  }
}

class _ScanView extends StatefulWidget {
  const _ScanView({required this.onCode});
  final void Function(String) onCode;
  @override
  State<_ScanView> createState() => _ScanViewState();
}

class _ScanViewState extends State<_ScanView> {
  bool _done = false;
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: MobileScanner(onDetect: (capture) {
        if (_done) return;
        for (final b in capture.barcodes) {
          final v = b.rawValue;
          if (v != null && v.startsWith('ptp://pair?')) {
            _done = true;
            widget.onCode(v);
            return;
          }
        }
      }),
    );
  }
}

class _ConfirmView extends StatelessWidget {
  const _ConfirmView({required this.c});
  final MigrationController c;
  @override
  Widget build(BuildContext context) {
    final peer = c.pendingPeer!;
    return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(S.t('confirm_title'), style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      Text(S.t('confirm_body', {'name': peer.name, 'platform': peer.platform == 'ios' ? 'iPhone' : 'Android'}),
          textAlign: TextAlign.center),
      const SizedBox(height: 24),
      Text(
        '${c.pendingSas!.substring(0, 3)} ${c.pendingSas!.substring(3)}',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.displayMedium?.copyWith(letterSpacing: 6, fontFeatures: const [FontFeature.tabularFigures()]),
        semanticsLabel: c.pendingSas!.split('').join(' '),
      ),
      const SizedBox(height: 32),
      FilledButton(onPressed: () => c.answerConfirm(true), child: Text(S.t('accept'))),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => c.answerConfirm(false), child: Text(S.t('reject'))),
    ]);
  }
}

class _SelectView extends StatelessWidget {
  const _SelectView({required this.c});
  final MigrationController c;

  @override
  Widget build(BuildContext context) {
    final peerPf = c.peer?.platform ?? '';
    final myPf = c.probe?.platform ?? (Platform.isIOS ? 'ios' : 'android');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(S.t('choose_data'), style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(children: [
          for (final cat in categoryRegistry) _categoryTile(context, cat, myPf, peerPf),
        ]),
      ),
      if (Platform.isIOS) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(S.t('keep_open_ios'), style: Theme.of(context).textTheme.bodySmall)),
      FilledButton(
        onPressed: c.selectedCount == 0 ? null : c.startSending,
        child: Text('${S.t('start')} · ${S.t('items', {'n': c.selectedCount})}'),
      ),
    ]);
  }

  Widget _categoryTile(BuildContext context, CategoryInfo cat, String myPf, String peerPf) {
    final inPlan = c.plan.contains(cat.id);
    final items = c.selection[cat.id];
    final perm = c.permission[cat.id];
    final note = '${cat.forPlatform(myPf).note}\n→ ${cat.forPlatform(peerPf).note}';
    String subtitle;
    if (!inPlan) {
      subtitle = S.t('not_in_plan');
    } else if (perm == 'denied') {
      subtitle = S.t('perm_denied');
    } else if (items != null) {
      final size = items.fold<int>(0, (a, i) => a + i.sizeHint);
      subtitle = '${S.t('items', {'n': items.length})}${size > 0 ? ' · ${fmtBytes(size)}' : ''}'
          '${perm == 'limited' ? ' · ${S.t('perm_limited')}' : ''}';
    } else {
      subtitle = statusLabel(cat.forPlatform(myPf).export);
    }
    return Card(
      child: ListTile(
        enabled: inPlan,
        title: Text(cat.titleVi),
        subtitle: Text(subtitle),
        isThreeLine: false,
        leading: Checkbox(
          value: items != null && items.isNotEmpty,
          onChanged: !inPlan
              ? null
              : (v) {
                  if (v == true) {
                    c.selectCategory(cat.id);
                  } else {
                    c.clearCategory(cat.id);
                  }
                },
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (perm == 'denied') ...[
            TextButton(onPressed: () => c.selectCategory(cat.id), child: Text(S.t('grant'))),
            // P1-6: after a permanent denial the OS no longer shows the prompt; Settings is the only way back.
            IconButton(
              tooltip: S.t('open_settings'),
              icon: const Icon(Icons.settings_rounded),
              onPressed: PtpPlatform.openAppSettings,
            ),
          ],
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => showDialog<void>(
                context: context, builder: (_) => AlertDialog(title: Text(cat.titleVi), content: Text(note))),
          ),
        ]),
      ),
    );
  }
}

class _ApproveView extends StatelessWidget {
  const _ApproveView({required this.c});
  final MigrationController c;
  @override
  Widget build(BuildContext context) {
    final m = c.pendingManifest!;
    final byCat = <String, int>{};
    for (final f in m.files) {
      byCat[f.category] = (byCat[f.category] ?? 0) + 1;
    }
    return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(S.t('approve_title'), style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      Text(S.t('approve_body', {'n': m.files.length, 'size': fmtBytes(c.pendingNeeded)})),
      const SizedBox(height: 8),
      for (final e in byCat.entries)
        Text('• ${categoryRegistry.firstWhere((x) => x.id == e.key).titleVi}: ${e.value}'),
      const SizedBox(height: 24),
      FilledButton(onPressed: () => c.answerApprove(true), child: Text(S.t('accept'))),
      OutlinedButton(onPressed: () => c.answerApprove(false), child: Text(S.t('reject'))),
    ]);
  }
}

class _TransferView extends StatelessWidget {
  const _TransferView({required this.c});
  final MigrationController c;
  @override
  Widget build(BuildContext context) {
    final pr = c.progress;
    final frac = pr.totalBytes > 0 ? (pr.doneBytes / pr.totalBytes).clamp(0.0, 1.0) : null;
    final tt = Theme.of(context).textTheme;
    return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(c.state == MigrationState.importing ? S.t('importing') : S.t('transferring'), style: tt.headlineSmall),
      const SizedBox(height: 16),
      LinearProgressIndicator(value: frac, minHeight: 10, borderRadius: BorderRadius.circular(5)),
      const SizedBox(height: 8),
      Text('${fmtBytes(pr.doneBytes)} / ${pr.totalBytes > 0 ? fmtBytes(pr.totalBytes) : '…'}'),
      if (pr.mbps > 0) Text(S.t('speed', {'mbps': pr.mbps.toStringAsFixed(1)})),
      const SizedBox(height: 8),
      Text(pr.current, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall),
      if (c.reconnecting) ...[
        const SizedBox(height: 16),
        Row(children: [const Icon(Icons.wifi_off_rounded), const SizedBox(width: 8), Expanded(child: Text(S.t('reconnecting')))]),
      ],
      if (c.deviceWarning != null) ...[
        const SizedBox(height: 16),
        Row(children: [const Icon(Icons.warning_amber_rounded), const SizedBox(width: 8), Expanded(child: Text(S.t(c.deviceWarning!)))]),
      ],
      if (Platform.isIOS) ...[const SizedBox(height: 16), Text(S.t('keep_open_ios'), style: tt.bodySmall)],
      const SizedBox(height: 32),
      if (c.role == 'sender')
        OutlinedButton(onPressed: c.togglePause, child: Text(c.userPaused ? S.t('resume') : S.t('pause'))),
      TextButton(onPressed: c.cancel, child: Text(S.t('cancel'))),
    ]);
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.c});
  final MigrationController c;
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final (title, icon) = switch (c.state) {
      MigrationState.completed => (S.t('done_ok'), Icons.check_circle_rounded),
      MigrationState.partial => (S.t('done_partial'), Icons.error_outline_rounded),
      MigrationState.cancelled => (S.t('done_cancelled'), Icons.cancel_outlined),
      _ => (S.t('done_failed'), Icons.error_rounded),
    };
    final needsAction = c.imports.where((i) => i.status != 'imported').toList();
    final deniedImport = c.importPermission.entries.where((e) => e.value == 'denied').map((e) => e.key).toList();
    return ListView(children: [
      Icon(icon, size: 64),
      const SizedBox(height: 8),
      Text(title, textAlign: TextAlign.center, style: tt.headlineSmall),
      if (c.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(errorText(c.error!), textAlign: TextAlign.center)),
      const SizedBox(height: 16),
      ListTile(leading: const Icon(Icons.verified_rounded), title: Text(S.t('report_ok', {'n': c.okCount}))),
      if (c.failedCount > 0) ListTile(leading: const Icon(Icons.close_rounded), title: Text(S.t('report_failed', {'n': c.failedCount}))),
      if (c.skippedCount > 0) ListTile(leading: const Icon(Icons.block_rounded), title: Text(S.t('report_skipped', {'n': c.skippedCount}))),
      if (needsAction.isNotEmpty) ...[
        ListTile(leading: const Icon(Icons.touch_app_rounded), title: Text(S.t('report_action', {'n': needsAction.length}))),
        for (final i in needsAction.take(50))
          ListTile(dense: true, title: Text(i.name), subtitle: Text('${i.status} · ${i.location ?? ''} ${i.message ?? ''}')),
      ],
      if (deniedImport.isNotEmpty)
        ListTile(
          leading: const Icon(Icons.lock_outline_rounded),
          title: Text(S.t('import_denied', {'cats': deniedImport.join(', ')})),
          trailing: TextButton(onPressed: PtpPlatform.openAppSettings, child: Text(S.t('open_settings'))),
        ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        icon: const Icon(Icons.bug_report_outlined),
        label: Text(S.t('export_log')),
        onPressed: () async {
          final where = await c.exportLog();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.t('log_saved', {'where': where ?? '—'}))));
          }
        },
      ),
      if (c.role == 'receiver' && (c.state == MigrationState.failed || c.state == MigrationState.cancelled))
        OutlinedButton(onPressed: c.deletePartials, child: Text(S.t('delete_partial'))),
      FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(S.t('finish'))),
    ]);
  }
}
