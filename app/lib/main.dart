import 'package:flutter/material.dart';

import 'app/controller.dart';
import 'data/db.dart';
import 'l10n/strings.dart';
import 'ui/clay.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  runApp(PhoneTransferApp(controller: MigrationController(db)));
}

class PhoneTransferApp extends StatelessWidget {
  const PhoneTransferApp({super.key, required this.controller});
  final MigrationController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: S.t('app_title'),
      debugShowCheckedModeBanner: false,
      // "Đất sét 3D" design (light only: the clay shadows are built for a light background).
      theme: Clay.theme(),
      themeMode: ThemeMode.light,
      home: HomeScreen(controller: controller),
    );
  }
}
