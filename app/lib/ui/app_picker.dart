// Pick which installed apps to send (category "apps", Android → Android). NOT TESTED ON DEVICES.
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../l10n/strings.dart';
import 'clay.dart';
import 'flow_screen.dart' show fmtBytes;

class AppPickerScreen extends StatefulWidget {
  const AppPickerScreen({super.key, required this.c});
  final MigrationController c;

  @override
  State<AppPickerScreen> createState() => _AppPickerScreenState();
}

class _AppPickerScreenState extends State<AppPickerScreen> {
  late final Set<String> _picked = {...?widget.c.selection['apps']?.map((a) => a.id)};

  @override
  Widget build(BuildContext context) {
    final apps = widget.c.appsCatalog;
    final size = apps.where((a) => _picked.contains(a.id)).fold<int>(0, (s, a) => s + a.sizeHint);
    return Scaffold(
      backgroundColor: Clay.bg,
      appBar: AppBar(
        backgroundColor: Clay.bg,
        title: Text(S.t('apps_pick_title')),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              if (_picked.length == apps.length) {
                _picked.clear();
              } else {
                _picked.addAll(apps.map((a) => a.id));
              }
            }),
            child: Text(S.t(_picked.length == apps.length ? 'apps_none' : 'apps_all')),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: ClayNote(text: S.t('apps_pick_note'), icon: Icons.info_outline_rounded),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: apps.length,
            itemBuilder: (_, i) {
              final a = apps[i];
              return CheckboxListTile(
                value: _picked.contains(a.id),
                onChanged: (v) => setState(() => v == true ? _picked.add(a.id) : _picked.remove(a.id)),
                title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(fmtBytes(a.sizeHint)),
                secondary: const Icon(Icons.android_rounded),
              );
            },
          ),
        ),
        SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ClayPrimaryButton(
            icon: Icons.check_rounded,
            label: '${S.t('apps_done', {'n': _picked.length})}${size > 0 ? ' · ${fmtBytes(size)}' : ''}',
            onPressed: () {
              widget.c.setAppSelection(_picked);
              Navigator.of(context).pop();
            },
          ),
        ),
      ]),
    );
  }
}
