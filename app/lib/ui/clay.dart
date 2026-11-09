/// "Đất sét 3D" (claymorphism) look, from the approved design canvas (phương án G):
/// one soft background colour, raised surfaces (light from top-left, shade to bottom-right), pressed/inset wells,
/// a lavender-blue gradient for the primary action, Quicksand font.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class Clay {
  static const bg = Color(0xFFE9EEF6);
  static const fg = Color(0xFF2C3550);
  static const sub = Color(0xFF6C7695);
  static const accent = Color(0xFF6C8CFF);
  static const accent2 = Color(0xFFB18CFF);
  static const shade = Color(0xFFC5CCDA);
  static const light = Color(0xFFFFFFFF);
  static const danger = Color(0xFFC2413A);
  static const warn = Color(0xFFB2620F);
  static const warnBg = Color(0xFFF6E9DA);
  static const warnFg = Color(0xFF7A4810);
  static const track = Color(0xFFD7DDEA);
  static const font = 'Quicksand';

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8AA3FF), Color(0xFF5E7CF2)],
  );

  static List<BoxShadow> raised([double d = 10]) => [
        BoxShadow(color: shade, offset: Offset(d, d), blurRadius: d * 2.4),
        BoxShadow(color: light, offset: Offset(-d, -d), blurRadius: d * 2.4),
      ];

  static List<BoxShadow> puff() => const [
        BoxShadow(color: Color(0xFFBFC7D8), offset: Offset(8, 8), blurRadius: 20),
        BoxShadow(color: light, offset: Offset(-8, -8), blurRadius: 20),
      ];

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      fontFamily: font,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, surface: bg, primary: const Color(0xFF5E7CF2), error: danger),
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: fg,
        centerTitle: false,
        titleTextStyle: TextStyle(fontFamily: font, fontSize: 19, fontWeight: FontWeight.w700, color: fg),
      ),
      textTheme: base.textTheme.apply(bodyColor: fg, displayColor: fg, fontFamily: font),
      cardTheme: const CardThemeData(color: bg, elevation: 0, margin: EdgeInsets.symmetric(vertical: 6)),
      listTileTheme: const ListTileThemeData(iconColor: accent, textColor: fg),
      dividerColor: track,
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: fg),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent, linearTrackColor: track),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : Colors.transparent),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}

/// Raised clay surface.
class ClaySurface extends StatelessWidget {
  const ClaySurface({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.radius = 28, this.depth = 10, this.onTap, this.color});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double depth;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final box = DecoratedBox(
      decoration: BoxDecoration(color: color ?? Clay.bg, borderRadius: r, boxShadow: Clay.raised(depth)),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(borderRadius: r, onTap: onTap, child: Padding(padding: padding, child: child)),
      ),
    );
    return box;
  }
}

/// Pressed-in clay well (inner shadows; BoxShadow has no inset, so it is painted).
class ClayInset extends StatelessWidget {
  const ClayInset({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.radius = 20, this.depth = 6, this.color = Clay.bg});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double depth;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _InsetPainter(radius, depth, color),
        child: Padding(padding: padding, child: child),
      );
}

class _InsetPainter extends CustomPainter {
  _InsetPainter(this.radius, this.depth, this.color);
  final double radius;
  final double depth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.drawRRect(rr, Paint()..color = color);
    canvas.save();
    canvas.clipRRect(rr);
    void shadow(Color c, Offset o) {
      final path = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rr.outerRect.inflate(depth * 4))
        ..addRRect(rr.shift(o));
      canvas.drawPath(path, Paint()
        ..color = c
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, depth));
    }

    shadow(const Color(0xFFC9D0DD), Offset(depth, depth));
    shadow(Colors.white, Offset(-depth, -depth));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InsetPainter old) => old.radius != radius || old.depth != depth || old.color != color;
}

/// Puffy gradient button for the main action. Disabled when [onPressed] is null.
class ClayPrimaryButton extends StatelessWidget {
  const ClayPrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.height = 58});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final r = BorderRadius.circular(22);
    return Semantics(
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: Clay.gradient, borderRadius: r, boxShadow: enabled ? Clay.puff() : null),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: r,
              onTap: onPressed,
              child: Container(
                constraints: BoxConstraints(minHeight: height),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  borderRadius: r,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white.withValues(alpha: 0.18), Colors.transparent, const Color(0xFF1E3296).withValues(alpha: 0.18)],
                  ),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, color: Colors.white, size: 20), const SizedBox(width: 10)],
                  Flexible(
                    child: Text(label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontFamily: Clay.font, color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Raised neutral button (secondary actions). [color] tints the label (e.g. danger for "Hủy").
class ClayButton extends StatelessWidget {
  const ClayButton({super.key, required this.label, required this.onPressed, this.icon, this.color = Clay.fg, this.height = 52});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: ClaySurface(
        radius: 20,
        depth: 6,
        padding: EdgeInsets.zero,
        onTap: onPressed,
        child: Container(
          constraints: BoxConstraints(minHeight: height),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          alignment: Alignment.center,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, color: color, size: 19), const SizedBox(width: 8)],
            Flexible(
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: Clay.font, color: color, fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Rounded icon blob: gradient (filled), raised or pressed.
class ClayBlob extends StatelessWidget {
  const ClayBlob({super.key, required this.icon, this.size = 52, this.filled = false, this.pressed = false, this.iconColor});
  final IconData icon;
  final double size;
  final bool filled;
  final bool pressed;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final r = size * 0.36;
    final ic = Icon(icon, size: size * 0.48, color: iconColor ?? (filled ? Colors.white : Clay.accent));
    if (pressed) {
      return SizedBox(width: size, height: size, child: ClayInset(radius: r, depth: 4, padding: EdgeInsets.zero, child: Center(child: ic)));
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Clay.bg,
        gradient: filled ? Clay.gradient : null,
        borderRadius: BorderRadius.circular(r),
        boxShadow: filled ? Clay.puff() : Clay.raised(6),
      ),
      child: Center(child: ic),
    );
  }
}

/// Inset track with a gradient fill. [value] null = indeterminate stripe.
class ClayProgressBar extends StatelessWidget {
  const ClayProgressBar({super.key, required this.value, this.height = 14});
  final double? value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ClayInset(
        radius: height,
        depth: 3,
        padding: const EdgeInsets.all(3),
        child: value == null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(height),
                child: const LinearProgressIndicator(backgroundColor: Colors.transparent, color: Clay.accent))
            : LayoutBuilder(
                builder: (_, c) => Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: c.maxWidth * value!.clamp(0.0, 1.0),
                    decoration: BoxDecoration(gradient: Clay.gradient, borderRadius: BorderRadius.circular(height)),
                  ),
                ),
              ),
      ),
    );
  }
}

/// Big progress ring on a raised disc. [value] null = waiting (no fake number).
class ClayRing extends StatelessWidget {
  const ClayRing({super.key, required this.value, required this.center, this.size = 210});
  final double? value;
  final Widget center;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Clay.bg, shape: BoxShape.circle, boxShadow: Clay.raised(6)),
      child: Stack(alignment: Alignment.center, children: [
        if (value == null)
          SizedBox(width: size * 0.76, height: size * 0.76, child: const CircularProgressIndicator(strokeWidth: 14, color: Clay.accent))
        else
          CustomPaint(size: Size.square(size), painter: _RingPainter(value!.clamp(0.0, 1.0))),
        center,
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value);
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.38;
    const stroke = 17.0;
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Clay.track);
    if (value <= 0) return;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * value,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..shader = const SweepGradient(
            startAngle: -math.pi / 2,
            endAngle: 3 * math.pi / 2,
            colors: [Color(0xFF8AA3FF), Clay.accent2],
            transform: GradientRotation(-math.pi / 2),
          ).createShader(rect));
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value;
}

/// Pressed segmented control: the selected option is raised.
class ClaySegmented<T> extends StatelessWidget {
  const ClaySegmented({super.key, required this.options, required this.value, required this.onChanged});
  final List<(T, IconData, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ClayInset(
      radius: 22,
      depth: 5,
      padding: const EdgeInsets.all(6),
      child: Row(children: [
        for (final (v, icon, label) in options)
          Expanded(
            child: Semantics(
              selected: v == value,
              button: true,
              child: GestureDetector(
                onTap: () => onChanged(v),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  constraints: const BoxConstraints(minHeight: 46),
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: v == value ? Clay.bg : Colors.transparent,
                    borderRadius: BorderRadius.circular(17),
                    boxShadow: v == value ? Clay.raised(4) : null,
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(icon, size: 18, color: v == value ? Clay.accent : Clay.sub),
                    const SizedBox(height: 2),
                    Text(label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: Clay.font,
                            fontSize: 13,
                            fontWeight: v == value ? FontWeight.w700 : FontWeight.w600,
                            color: v == value ? Clay.accent : Clay.sub)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Orange note box (warnings / "you need to act").
class ClayNote extends StatelessWidget {
  const ClayNote({super.key, required this.text, this.icon = Icons.info_outline_rounded});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => ClayInset(
        color: Clay.warnBg,
        radius: 20,
        depth: 3,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: const Color(0xFF9A5B12)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13, height: 1.45, fontWeight: FontWeight.w600, color: Clay.warnFg)),
          ),
        ]),
      );
}

/// Step header line used under the app bar ("Bước 2 / 4 · …").
class ClayStep extends StatelessWidget {
  const ClayStep(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Clay.sub));
}
