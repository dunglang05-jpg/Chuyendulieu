// Layout smoke test of the "Đất sét 3D" widgets: they must lay out on a phone-sized screen without overflow
// or exceptions, buttons must respect enabled/disabled, and the segmented control must report the choice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_transfer_pro/ui/clay.dart';

void main() {
  testWidgets('clay widgets render on a 390x844 screen and react to taps', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var pressed = 0;
    String mode = 'wifi';
    await tester.pumpWidget(MaterialApp(
      theme: Clay.theme(),
      home: Scaffold(
        body: StatefulBuilder(
          // Column in a scroll view (not a lazy ListView) so every widget is built and laid out.
          builder: (context, setState) => SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ClaySegmented<String>(
              options: const [
                ('wifi', Icons.wifi_rounded, 'Wi-Fi / mạng'),
                ('auto', Icons.swap_horiz_rounded, 'Tự động'),
                ('usb', Icons.usb_rounded, 'Chỉ cáp'),
              ],
              value: mode,
              onChanged: (v) => setState(() => mode = v),
            ),
            const SizedBox(height: 16),
            const ClayRing(value: 0.64, center: Text('64%')),
            const ClayRing(value: null, center: Text('…')),
            const ClayProgressBar(value: 0.41),
            const ClayProgressBar(value: null),
            const ClayNote(text: 'Nếu mã khác nhau, có thể bạn đang kết nối nhầm máy. Hãy từ chối.'),
            const ClayBlob(icon: Icons.check_rounded, filled: true),
            const ClayBlob(icon: Icons.image_outlined, pressed: true),
            ClaySurface(child: const Text('Ảnh · 2.341'), onTap: () {}),
            ClayPrimaryButton(label: 'Bắt đầu chuyển', onPressed: () => pressed++),
            const ClayPrimaryButton(label: 'Tắt', onPressed: null),
            ClayButton(label: 'Hủy', color: Clay.danger, onPressed: () => pressed++),
          ])),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Tự động'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(mode, 'auto');

    await tester.ensureVisible(find.text('Bắt đầu chuyển'));
    await tester.tap(find.text('Bắt đầu chuyển'));
    await tester.ensureVisible(find.text('Tắt'));
    await tester.tap(find.text('Tắt'));
    await tester.ensureVisible(find.text('Hủy'));
    await tester.tap(find.text('Hủy'));
    expect(pressed, 2, reason: 'the disabled button does nothing');
  });
}
