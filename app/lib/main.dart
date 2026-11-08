import 'package:flutter/material.dart';

import 'app/controller.dart';
import 'data/db.dart';
import 'l10n/strings.dart';
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
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6E4F), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF0B6E4F), brightness: Brightness.dark, useMaterial3: true),
      home: HomeScreen(controller: controller),
    );
  }
}
