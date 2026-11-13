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
import '../core/transfer/path_policy.dart';
import '../l10n/strings.dart';
import 'clay.dart';
import 'app_picker.dart';
import 'info_screens.dart';

String fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

IconData categoryIcon(String id) => switch (id) {
      'photos' => Icons.image_outlined,
      'videos' => Icons.videocam_outlined,
      'contacts' => Icons.person_outline_rounded,
      'documents' => Icons.description_outlined,
      'audio' => Icons.music_note_outlined,
      'apps' => Icons.apps_rounded,
      _ => Icons.folder_outlined,
    };

String errorText(PtpException e) => switch (e.code) {
      PtpErrorCode.pairingExpired => S.t('err_qr_expired'),
      PtpErrorCode.peerTimeout || PtpErrorCode.networkInterrupted => S.t('err_connect'),
      PtpErrorCode.authenticationFailed => S.t('err_auth'),
      PtpErrorCode.protocolVersionMismatch => S.t('err_version'),
      PtpErrorCode.storageInsufficient => S.t('err_storage'),
      PtpErrorCode.permissionDenied => S.t('err_permission'),
      PtpErrorCode.hashMismatch => S.t('err_hash'),
      PtpErrorCode.userCancelled => S.t('err_cancelled'),
      PtpErrorCode.platformRestriction => usbReason(e.message),
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
  // User request 2026-11-09: no shared Wi-Fi needed by default → "Điểm phát" on Android (iPhone cannot host it).
  String _mode = Platform.isAndroid ? 'hotspot' : 'wifi'; // hotspot | wifi | auto | usb
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
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.role == 'sender' ? S.t('send') : S.t('receive'))),
        body: SafeArea(
          child: AnimatedBuilder(
            animation: c,
            builder: (context, _) => Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), child: _body(context)),
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
              }) : _ConnectChoice(
                role: widget.role,
                mode: _mode,
                onTransport: (v) => setState(() => _mode = v),
                onShow: () => c.showQr(widget.role, mode: _mode),
                onScan: () => setState(() => _scanning = true));
      case MigrationState.discovering:
      case MigrationState.pairing:
        if (c.qrUri != null) return _QrView(c: c, role: widget.role);
        if (c.hotspotManual != null) return _HotspotManualView(c: c);
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            if (c.transport == 'usb') ...[const SizedBox(height: 16), _UsbStatus(c: c)],
          ]),
        );
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
  const _ConnectChoice(
      {required this.role, required this.mode, required this.onTransport, required this.onShow, required this.onScan});
  final String role;
  final String mode;
  final ValueChanged<String> onTransport;
  final VoidCallback onShow;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    // Default: the new phone (receiver) shows the code, the old phone scans. Either way works.
    // iPhone cannot create the direct Wi-Fi, so there it scans the Android phone's code first.
    final showFirst = role == 'receiver' && Platform.isAndroid;
    final show = ClayPrimaryButton(onPressed: onShow, icon: Icons.qr_code_2_rounded, label: S.t('show_qr'));
    final scan = ClayButton(onPressed: onScan, icon: Icons.qr_code_scanner_rounded, label: S.t('scan_qr'));
    return ListView(children: [
      ClayStep(S.t('step_connect')),
      const SizedBox(height: 18),
      if (Platform.isAndroid) ...[
        // Wi-Fi stays the default; both cable modes are experimental until real-device tests pass.
        // Cable modes are Android only: iPhone apps have no public USB API (docs/USB_C_OTG_RESEARCH.md).
        ClaySegmented<String>(
          options: [
            ('hotspot', Icons.wifi_tethering_rounded, S.t('transport_hotspot')),
            ('wifi', Icons.wifi_rounded, S.t('transport_wifi')),
            ('auto', Icons.swap_horiz_rounded, S.t('transport_auto')),
            ('usb', Icons.usb_rounded, S.t('transport_usb')),
          ],
          value: mode,
          onChanged: onTransport,
        ),
        const SizedBox(height: 20),
      ],
      ClaySurface(
        radius: 26,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClayBlob(
              icon: switch (mode) {
                'usb' => Icons.usb_rounded,
                'auto' => Icons.swap_horiz_rounded,
                'hotspot' => Icons.wifi_tethering_rounded,
                _ => Icons.wifi_rounded
              },
              size: 44,
              pressed: true),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
                switch (mode) {
                  'usb' => S.t('usb_hint'),
                  'auto' => S.t('auto_hint'),
                  'hotspot' => S.t('hotspot_hint'),
                  _ => S.t('same_wifi')
                },
                style: const TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w600, color: Clay.sub)),
          ),
        ]),
      ),
      if (!Platform.isAndroid) ...[
        const SizedBox(height: 10),
        ClayNote(text: S.t('ios_scan_hint'), icon: Icons.wifi_tethering_rounded),
        const SizedBox(height: 10),
        Text(S.t('usb_ios_unsupported'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Clay.sub)),
      ],
      const SizedBox(height: 32),
      showFirst ? show : scan,
      const SizedBox(height: 18),
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
    return ListView(children: [
      ClayStep(S.t('step_connect')),
      const SizedBox(height: 18),
      ClaySurface(
        radius: 34,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
        child: Column(children: [
          Text(S.t('qr_hint'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Clay.sub)),
          const SizedBox(height: 18),
          ClayInset(
            color: Colors.white,
            radius: 26,
            padding: const EdgeInsets.all(16),
            child: QrImageView(
              data: widget.c.qrUri!,
              size: 220,
              semanticsLabel: 'QR',
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Clay.fg),
              dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Clay.fg),
            ),
          ),
          const SizedBox(height: 18),
          if (left > 0) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(S.t('qr_expires', {'s': left}),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Clay.sub)),
            ),
            const SizedBox(height: 8),
            ClayProgressBar(value: left / 300, height: 12),
          ] else
            ClayPrimaryButton(onPressed: () => widget.c.showQr(widget.role), label: S.t('qr_new'), icon: Icons.refresh_rounded),
        ]),
      ),
      if (widget.c.transport == 'usb') ...[const SizedBox(height: 16), _UsbStatus(c: widget.c)],
      if (widget.c.transport == 'hotspot') ...[
        const SizedBox(height: 16),
        ClayNote(
            text: S.t('hotspot_qr_note', {
              'band': switch (widget.c.hotspotBand) { '5' => '5 GHz ', '2' => '2,4 GHz ', _ => '' }
            }),
            icon: Icons.wifi_tethering_rounded),
        if (widget.c.hotspotBand == '5')
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
                onPressed: () => widget.c.showQr(widget.role, mode: 'hotspot', force24: true),
                child: Text(S.t('hotspot_use_24'))),
          ),
      ],
      if (loopbackOnly && widget.c.transport != 'usb') ...[
        const SizedBox(height: 16),
        ClayNote(text: S.t('no_wifi_ip'), icon: Icons.wifi_off_rounded),
      ],
    ]);
  }
}

/// Which link the session is on right now and, in "Tự động", why (from real measurements only).
class _PathInfo extends StatelessWidget {
  const _PathInfo({required this.c});
  final MigrationController c;
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    String? note;
    if (c.switchingPath) {
      note = S.t(c.pathReason == PathReason.cableConnected || c.pathReason == PathReason.wifiUnmeasured
          ? 'path_moving_cable'
          : 'path_moving_wifi');
    } else if (c.pathReason == PathReason.cableSlower) {
      note = S.t('path_cable_slower', {
        'cable': c.pathCableMbps?.toStringAsFixed(1) ?? '?',
        'wifi': c.pathWifiMbps?.toStringAsFixed(1) ?? '?',
      });
    } else if (c.pathReason == PathReason.cableNoData) {
      note = S.t('path_cable_nodata');
    } else if (c.pathReason == PathReason.cableLost) {
      note = S.t('path_cable_lost');
    } else if (c.autoCable && c.cableArmed && !c.onCable) {
      note = S.t('path_plug_hint');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(c.onCable ? Icons.usb_rounded : Icons.wifi_rounded),
        const SizedBox(width: 8),
        Expanded(child: Text(S.t(c.onCable ? 'path_on_cable' : 'path_on_wifi'))),
      ]),
      if (note != null) ...[const SizedBox(height: 4), Text(note, style: tt.bodySmall)],
    ]);
  }
}

/// Real state reported by the native USB transport (no simulated values).
class _UsbStatus extends StatelessWidget {
  const _UsbStatus({required this.c});
  final MigrationController c;

  @override
  Widget build(BuildContext context) {
    final state = c.usbState ?? 'waiting';
    final role = switch (c.usbRole) {
      'usb_host' => S.t('usb_role_host'),
      'usb_accessory' => S.t('usb_role_accessory'),
      _ => '',
    };
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(state == 'connected' ? Icons.usb_rounded : Icons.usb_off_rounded),
        const SizedBox(width: 8),
        Flexible(child: Text(S.t('usb_state_$state'))),
      ]),
      if (role.isNotEmpty) Text(role, style: Theme.of(context).textTheme.bodySmall),
      if (c.usbNoHostHint) ...[
        const SizedBox(height: 12),
        ClayNote(text: S.t('usb_no_host'), icon: Icons.cable_rounded),
      ],
      if (c.usbSeen == 'denied' && c.usbState != 'connected') ...[
        const SizedBox(height: 12),
        ClayNote(text: S.t('usb_denied_hint'), icon: Icons.cable_rounded),
      ],
      if (c.usbSeen == 'not_android') ...[
        const SizedBox(height: 12),
        ClayNote(text: S.t('usb_not_android'), icon: Icons.cable_rounded),
      ],
      if (state == 'failed' && c.usbError != null)
        Text(usbReason(c.usbError!), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ]);
  }
}

/// Readable reason for an import that needs attention (falls back to the raw status/codes).
String importNote(ImportOutcome i) {
  final m = i.message;
  if (m != null) {
    final t = S.t('imp_$m');
    if (t != 'imp_$m') return t;
  }
  return '${i.status} · ${i.location ?? ''} ${m ?? ''}';
}

String usbReason(String code) {
  if (code.startsWith('HOTSPOT')) {
    final t = S.t('hs_err_$code');
    return t == 'hs_err_$code' ? S.t('hs_err_generic', {'code': code}) : t;
  }
  final key = 'usb_err_${code.split(':').first}';
  final t = S.t(key);
  return t == key ? S.t('usb_err_generic', {'code': code}) : t;
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
    final sas = c.pendingSas!;
    final platform = peer.platform == 'ios' ? 'iPhone' : 'Android';
    Widget digit(String d) => SizedBox(
          width: 44,
          height: 58,
          child: ClayInset(
            radius: 16,
            depth: 5,
            padding: EdgeInsets.zero,
            child: Center(
              child: Text(d,
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ),
        );
    return ListView(children: [
      ClayStep(S.t('step_confirm')),
      const SizedBox(height: 22),
      const Center(child: ClayBlob(icon: Icons.verified_user_outlined, size: 92, filled: true)),
      const SizedBox(height: 18),
      Text(S.t('confirm_body', {'name': peer.name, 'platform': platform}),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, height: 1.45, fontWeight: FontWeight.w600, color: Clay.sub)),
      const SizedBox(height: 20),
      ClaySurface(
        radius: 26,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(children: [
          const ClayBlob(icon: Icons.smartphone_rounded, size: 46, pressed: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(peer.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(platform, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Clay.sub)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 20),
      ClaySurface(
        radius: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 20),
        child: Column(children: [
          Text(S.t('confirm_code'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Clay.sub, letterSpacing: 1)),
          const SizedBox(height: 12),
          Semantics(
            label: sas.split('').join(' '),
            excludeSemantics: true,
            child: FittedBox(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < sas.length; i++) ...[
                  if (i == 3) const SizedBox(width: 12) else if (i > 0) const SizedBox(width: 6),
                  digit(sas[i]),
                ],
              ]),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 20),
      ClayNote(text: S.t('confirm_warn'), icon: Icons.warning_amber_rounded),
      const SizedBox(height: 26),
      ClayPrimaryButton(onPressed: () => c.answerConfirm(true), icon: Icons.check_rounded, label: S.t('accept_same')),
      const SizedBox(height: 16),
      ClayButton(onPressed: () => c.answerConfirm(false), label: S.t('reject_diff'), color: Clay.danger),
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
    final total = c.selection.values.fold<int>(0, (a, l) => a + l.fold<int>(0, (b, i) => b + i.sizeHint));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClayStep(S.t('step_select', {'name': c.peer?.name ?? ''})),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 10), children: [
          for (final cat in categoryRegistry) ...[_categoryTile(context, cat, myPf, peerPf), const SizedBox(height: 14)],
          ClaySurface(
            radius: 24,
            depth: 6,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => AppsGuideScreen(myPlatform: myPf == 'ios' ? 'ios' : 'android'))),
            child: Row(children: [
              const ClayBlob(icon: Icons.apps_rounded, size: 44, pressed: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(S.t('apps_tile'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(S.t('apps_tile_sub'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Clay.sub)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: Clay.sub),
            ]),
          ),
          const SizedBox(height: 14),
          if (Platform.isIOS) Text(S.t('keep_open_ios'), style: const TextStyle(fontSize: 12, color: Clay.sub)),
        ]),
      ),
      const SizedBox(height: 8),
      ClaySurface(
        radius: 30,
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(S.t('items', {'n': c.selectedCount}),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Clay.sub)),
            ),
            if (total > 0) Text(fmtBytes(total), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 12),
          ClayPrimaryButton(onPressed: c.selectedCount == 0 ? null : c.startSending, label: S.t('start'), height: 56),
        ]),
      ),
    ]);
  }

  Widget _categoryTile(BuildContext context, CategoryInfo cat, String myPf, String peerPf) {
    final inPlan = c.plan.contains(cat.id);
    final items = c.selection[cat.id];
    final perm = c.permission[cat.id];
    final selected = items != null && items.isNotEmpty;
    final note = '${cat.forPlatform(myPf).note}\n→ ${cat.forPlatform(peerPf).note}';
    String subtitle;
    var subColor = Clay.sub;
    if (!inPlan) {
      subtitle = S.t('not_in_plan');
    } else if (perm == 'denied') {
      subtitle = S.t('perm_denied');
      subColor = Clay.warn;
    } else if (items != null) {
      final size = items.fold<int>(0, (a, i) => a + i.sizeHint);
      subtitle = '${S.t('items', {'n': items.length})}${size > 0 ? ' · ${fmtBytes(size)}' : ''}'
          '${perm == 'limited' ? ' · ${S.t('perm_limited')}' : ''}';
    } else {
      subtitle = statusLabel(cat.forPlatform(myPf).export);
    }
    Future<void> pickApps() async {
      if (!selected) await c.selectCategory('apps');
      if (!context.mounted || c.appsCatalog.isEmpty) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AppPickerScreen(c: c)));
    }

    void toggle() {
      if (!inPlan) return;
      if (cat.id == 'apps') {
        unawaited(pickApps()); // tapping again edits the choice instead of clearing it
        return;
      }
      if (selected) {
        c.clearCategory(cat.id);
      } else {
        c.selectCategory(cat.id);
      }
    }

    return Opacity(
      opacity: inPlan ? 1 : 0.5,
      child: ClaySurface(
        radius: 24,
        depth: 6,
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        onTap: inPlan ? toggle : null,
        child: Row(children: [
          ClayBlob(icon: categoryIcon(cat.id), size: 44, pressed: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(cat.titleVi, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(subtitle, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: subColor)),
            ]),
          ),
          if (perm == 'denied') ...[
            TextButton(onPressed: () => c.selectCategory(cat.id), child: Text(S.t('grant'))),
            // P1-6: after a permanent denial the OS no longer shows the prompt; Settings is the only way back.
            IconButton(
              tooltip: S.t('open_settings'),
              icon: const Icon(Icons.settings_rounded, color: Clay.sub),
              onPressed: PtpPlatform.openAppSettings,
            ),
          ],
          IconButton(
            tooltip: cat.titleVi,
            icon: const Icon(Icons.info_outline_rounded, color: Clay.sub),
            onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(backgroundColor: Clay.bg, title: Text(cat.titleVi), content: Text(note))),
          ),
          Semantics(
            checked: selected,
            enabled: inPlan,
            label: cat.titleVi,
            child: GestureDetector(
              onTap: inPlan ? toggle : null,
              child: Container(
                width: 32,
                height: 32,
                margin: const EdgeInsets.only(right: 6),
                child: selected
                    ? Container(
                        decoration: BoxDecoration(
                            gradient: Clay.gradient, borderRadius: BorderRadius.circular(12), boxShadow: Clay.raised(3)),
                        child: const Icon(Icons.check_rounded, color: Colors.white, size: 20),
                      )
                    : const ClayInset(radius: 12, depth: 3, padding: EdgeInsets.zero, child: SizedBox.expand()),
              ),
            ),
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
    return ListView(children: [
      const SizedBox(height: 12),
      const Center(child: ClayBlob(icon: Icons.move_to_inbox_rounded, size: 84, filled: true)),
      const SizedBox(height: 18),
      Text(S.t('approve_title'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(S.t('approve_body', {'n': m.files.length, 'size': fmtBytes(c.pendingNeeded)}),
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Clay.sub)),
      const SizedBox(height: 20),
      ClaySurface(
        radius: 26,
        child: Column(children: [
          for (final e in byCat.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(categoryIcon(e.key), color: Clay.accent, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(categoryRegistry.firstWhere((x) => x.id == e.key).titleVi,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                Text('${e.value}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Clay.sub)),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 28),
      ClayPrimaryButton(onPressed: () => c.answerApprove(true), icon: Icons.check_rounded, label: S.t('accept')),
      const SizedBox(height: 16),
      ClayButton(onPressed: () => c.answerApprove(false), label: S.t('reject'), color: Clay.danger),
    ]);
  }
}

class _TransferView extends StatelessWidget {
  const _TransferView({required this.c});
  final MigrationController c;

  /// Time left from the measured speed only; null when there is no measurement yet.
  String? _eta() {
    final pr = c.progress;
    if (pr.mbps <= 0 || pr.totalBytes <= 0) return null;
    final secs = (pr.totalBytes - pr.doneBytes) / (pr.mbps * 1e6);
    if (secs.isNaN || secs.isInfinite || secs < 0) return null;
    if (secs < 60) return '${secs.ceil()} s';
    if (secs < 3600) return '${(secs / 60).ceil()} min';
    return '${(secs / 3600).toStringAsFixed(1)} h';
  }

  @override
  Widget build(BuildContext context) {
    final pr = c.progress;
    final frac = pr.totalBytes > 0 ? (pr.doneBytes / pr.totalBytes).clamp(0.0, 1.0) : null;
    final eta = _eta();
    Widget stat(String label, String value) => Expanded(
          child: ClayInset(
            radius: 22,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Clay.sub)),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ),
        );
    return ListView(children: [
      ClayStep(c.state == MigrationState.importing ? S.t('importing') : S.t('step_transfer')),
      const SizedBox(height: 18),
      ClaySurface(
        radius: 36,
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
        child: Column(children: [
          ClayRing(
            value: frac,
            center: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(frac == null ? '…' : '${(frac * 100).floor()}%',
                  style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
              Text('${fmtBytes(pr.doneBytes)} / ${pr.totalBytes > 0 ? fmtBytes(pr.totalBytes) : '…'}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Clay.sub)),
            ]),
          ),
          const SizedBox(height: 14),
          if (pr.current.isNotEmpty)
            Text(S.t('now_sending', {'name': pr.current}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Clay.sub)),
        ]),
      ),
      const SizedBox(height: 18),
      Row(children: [
        stat(S.t('speed_label'), pr.mbps > 0 ? '${pr.mbps.toStringAsFixed(1)} MB/s' : '—'),
        const SizedBox(width: 16),
        stat(S.t('remaining'), eta ?? '—'),
      ]),
      if (c.continuedTransfer) ...[
        const SizedBox(height: 18),
        ClayNote(text: S.t('cont_resumed'), icon: Icons.restore_rounded),
      ],
      if (c.transport != 'wifi') ...[
        const SizedBox(height: 18),
        ClaySurface(radius: 24, depth: 6, padding: const EdgeInsets.all(16), child: _PathInfo(c: c)),
        // Auto mode: say why the cable is not taking over (device test 2026-11-09).
        if (c.autoCable && !c.onCable && c.usbSeen == 'denied') ...[
          const SizedBox(height: 12),
          ClayNote(text: S.t('usb_denied_hint'), icon: Icons.cable_rounded),
        ],
        if (c.autoCable && !c.onCable && c.usbSeen == 'not_android') ...[
          const SizedBox(height: 12),
          ClayNote(text: S.t('usb_not_android'), icon: Icons.cable_rounded),
        ],
      ],
      if (c.reconnecting && !c.switchingPath) ...[
        const SizedBox(height: 16),
        ClayNote(text: S.t(c.autoCable ? 'reconnecting_auto' : 'reconnecting'), icon: Icons.wifi_off_rounded),
      ],
      if (Platform.isAndroid && c.backgroundRestricted) ...[
        const SizedBox(height: 16),
        ClayNote(text: S.t('bg_restricted'), icon: Icons.battery_alert_rounded),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: c.openBatterySettings, child: Text(S.t('bg_open_settings'))),
        ),
      ],
      if (c.slowWifiMbps != null) ...[
        const SizedBox(height: 16),
        ClayNote(text: S.t('slow_wifi', {'mbps': c.slowWifiMbps!}), icon: Icons.network_check_rounded),
      ],
      if (c.deviceWarning != null) ...[
        const SizedBox(height: 16),
        ClayNote(text: S.t(c.deviceWarning!), icon: Icons.warning_amber_rounded),
      ],
      if (Platform.isIOS) ...[
        const SizedBox(height: 12),
        Text(S.t('keep_open_ios'), style: const TextStyle(fontSize: 12, color: Clay.sub)),
      ],
      const SizedBox(height: 26),
      Row(children: [
        if (c.role == 'sender') ...[
          Expanded(
            child: ClayButton(
              onPressed: c.togglePause,
              icon: c.userPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              label: c.userPaused ? S.t('resume') : S.t('pause'),
            ),
          ),
          const SizedBox(width: 16),
        ],
        Expanded(child: ClayButton(onPressed: c.cancel, label: S.t('cancel'), color: Clay.danger)),
      ]),
      const SizedBox(height: 8),
      Center(child: exportLogButton(context, c)),
    ]);
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.c});
  final MigrationController c;
  @override
  Widget build(BuildContext context) {
    final (title, icon, ok) = switch (c.state) {
      MigrationState.completed => (S.t('done_ok'), Icons.check_rounded, true),
      MigrationState.partial => (S.t('done_partial'), Icons.priority_high_rounded, false),
      MigrationState.cancelled => (S.t('done_cancelled'), Icons.close_rounded, false),
      _ => (S.t('done_failed'), Icons.error_outline_rounded, false),
    };
    final needsAction = c.imports.where((i) => i.status != 'imported').toList();
    final deniedImport = c.importPermission.entries.where((e) => e.value == 'denied').map((e) => e.key).toList();
    Widget stat(int n, String label, Color color) => Expanded(
          child: ClayInset(
            radius: 22,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
            child: Column(children: [
              Text('$n', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: color)),
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Clay.sub)),
            ]),
          ),
        );
    return ListView(children: [
      const SizedBox(height: 8),
      Center(
        child: ok
            ? ClayBlob(icon: icon, size: 96, filled: true)
            : ClayBlob(icon: icon, size: 96, iconColor: c.state == MigrationState.cancelled ? Clay.sub : Clay.danger),
      ),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
      if (c.error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(errorText(c.error!),
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Clay.sub)),
        ),
      const SizedBox(height: 20),
      Row(children: [
        stat(c.okCount, S.t('stat_ok'), Clay.accent),
        const SizedBox(width: 12),
        stat(c.failedCount, S.t('stat_failed'), Clay.danger),
        const SizedBox(width: 12),
        stat(c.skippedCount, S.t('stat_skipped'), Clay.sub),
      ]),
      const SizedBox(height: 18),
      ClaySurface(
        radius: 26,
        depth: 6,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(children: [
          ListTile(leading: const Icon(Icons.verified_rounded), title: Text(S.t('report_ok', {'n': c.okCount}))),
          if (c.failedCount > 0)
            ListTile(
                leading: const Icon(Icons.close_rounded, color: Clay.danger),
                title: Text(S.t('report_failed', {'n': c.failedCount}))),
          if (c.skippedCount > 0)
            ListTile(
                leading: const Icon(Icons.block_rounded, color: Clay.sub),
                title: Text(S.t('report_skipped', {'n': c.skippedCount}))),
        ]),
      ),
      if (needsAction.isNotEmpty) ...[
        const SizedBox(height: 16),
        ClayNote(text: S.t('report_action', {'n': needsAction.length}), icon: Icons.touch_app_rounded),
        for (final i in needsAction.take(50))
          ListTile(dense: true, title: Text(i.name), subtitle: Text(importNote(i))),
      ],
      if (deniedImport.isNotEmpty) ...[
        const SizedBox(height: 12),
        ListTile(
          leading: const Icon(Icons.lock_outline_rounded),
          title: Text(S.t('import_denied', {'cats': deniedImport.join(', ')})),
          trailing: TextButton(onPressed: PtpPlatform.openAppSettings, child: Text(S.t('open_settings'))),
        ),
      ],
      const SizedBox(height: 24),
      ClayPrimaryButton(onPressed: () => Navigator.of(context).pop(), label: S.t('finish')),
      const SizedBox(height: 16),
      ClayButton(
        icon: Icons.bug_report_outlined,
        label: S.t('export_log'),
        height: 48,
        onPressed: () async {
          final where = await c.exportLog();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.t('log_saved', {'where': where ?? '—'}))));
          }
        },
      ),
      if (c.role == 'receiver' && (c.state == MigrationState.failed || c.state == MigrationState.cancelled)) ...[
        const SizedBox(height: 14),
        ClayButton(onPressed: c.deletePartials, label: S.t('delete_partial'), height: 48),
      ],
    ]);
  }
}

/// Exports the diagnostic log (no file names, no contacts) to Downloads / Files, from any screen.
Widget exportLogButton(BuildContext context, MigrationController c) => TextButton.icon(
      icon: const Icon(Icons.bug_report_outlined, size: 18, color: Clay.sub),
      label: Text(S.t('export_log'), style: const TextStyle(fontWeight: FontWeight.w600, color: Clay.sub)),
      onPressed: () async {
        final where = await c.exportLog();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.t('log_saved', {'where': where ?? '—'}))));
        }
      },
    );

/// iPhone fallback for "Điểm phát": shows the host's hotspot name/password so the user can join in Settings.
class _HotspotManualView extends StatelessWidget {
  const _HotspotManualView({required this.c});
  final MigrationController c;

  @override
  Widget build(BuildContext context) {
    final ap = c.hotspotManual!;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(children: [
            SizedBox(width: 92, child: Text(label, style: const TextStyle(fontSize: 13, color: Clay.sub))),
            Expanded(
                child: SelectableText(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          ]),
        );
    return ListView(children: [
      ClayStep(S.t('step_connect')),
      const SizedBox(height: 18),
      ClaySurface(
        radius: 26,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(S.t('hotspot_manual_title'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(S.t('hotspot_manual_body'), style: const TextStyle(fontSize: 14, height: 1.45, color: Clay.sub)),
          row(S.t('hotspot_network'), ap.ssid),
          row(S.t('hotspot_password'), ap.psk),
        ]),
      ),
      const SizedBox(height: 28),
      ClayPrimaryButton(
          onPressed: c.continueManualJoin, icon: Icons.arrow_forward_rounded, label: S.t('hotspot_continue')),
    ]);
  }
}
