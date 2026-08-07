import 'package:flutter/material.dart';
import '../theme/app_motion.dart';

/// Ports design.css's global press-feedback system:
///   button:active { transform: scale(.9); opacity: .85 }
///   .tap:active      { transform: scale(.97); opacity: .7 }
///   .tap-cell:active { transform: scale(.94); opacity: .8 }
///   .tap-sm:active   { transform: scale(.9);  opacity: .7 }
///
/// Wrap anything tappable that isn't a themed ElevatedButton/TextButton in
/// this instead of a bare GestureDetector/InkWell, so every tap in the app
/// springs the same way the reference does.
enum PressableSize {
  /// .tap — large tap targets (full-width rows): press less so they don't
  /// lurch.
  large,

  /// .tap-cell — grid cells (profile video grid).
  cell,

  /// .tap-sm — small icon buttons.
  small,

  /// bare `button` — round controls (fab, nav side buttons): squash less so
  /// they don't look dented.
  round,
}

class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.size = PressableSize.large,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final PressableSize size;
  final BorderRadius? borderRadius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  (double scale, double opacity) get _pressedValues => switch (widget.size) {
        PressableSize.large => (AppMotion.tapScaleLarge, 0.7),
        PressableSize.cell => (AppMotion.tapScaleCell, 0.8),
        PressableSize.small => (AppMotion.tapScaleSmall, 0.7),
        PressableSize.round => (AppMotion.tapScaleRound, 1.0),
      };

  void _setPressed(bool value) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final (scale, opacity) = _pressedValues;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? scale : 1.0,
        duration: AppMotion.press,
        curve: AppMotion.pressCurve,
        child: AnimatedOpacity(
          opacity: _pressed ? opacity : 1.0,
          duration: const Duration(milliseconds: 150),
          child: widget.borderRadius != null
              ? ClipRRect(borderRadius: widget.borderRadius!, child: widget.child)
              : widget.child,
        ),
      ),
    );
  }
}
