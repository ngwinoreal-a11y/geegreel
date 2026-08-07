import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Ports design-4.css's skeleton system. Read the header comment in that
/// file before using a spinner instead of this: a bare "0"/spinner for
/// content whose shape is already known (feed, lists, profile grid,
/// comments) is explicitly called out as wrong there. Use [Skeleton] for
/// anything with a known shape; reserve a centred spinner/dots for short,
/// shapeless waits (see design-4.css section 2, "DOTS").
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 12,
    this.borderRadius = 6,
    this.onSheet = false,
  });

  /// .sk-av — round avatar skeleton.
  const Skeleton.avatar({super.key, required double size, this.onSheet = false})
      : width = size,
        height = size,
        borderRadius = size / 2;

  /// .sk-cell — 9:14 grid cell (profile video grid).
  const Skeleton.cell({super.key, this.onSheet = false})
      : width = double.infinity,
        height = null,
        borderRadius = 6;

  final double? width;
  final double? height;
  final double borderRadius;

  /// .sheet .sk — flips to the light skeleton pair when it sits on a white
  /// bottom sheet instead of the dark app background.
  final bool onSheet;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // .sk::after { animation: sweep 1.4s ease-in-out infinite }
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _box(double width, double height) {
    final base = widget.onSheet ? AppColors.skSheet : AppColors.skBase;
    final lift = widget.onSheet ? AppColors.skSheetLift : AppColors.skLift;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return FractionallySizedBox(
            alignment: Alignment(-1 + _controller.value * 2, 0),
            widthFactor: 0.6,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [base.withValues(alpha: 0), lift, base.withValues(alpha: 0)],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.height == null) {
      // Skeleton.cell: height comes from the 9:14 ratio applied to whatever
      // width the caller ends up with — computed explicitly via
      // LayoutBuilder rather than wrapping in AspectRatio, which mishandles
      // an unbounded/loose incoming width (produced a full-viewport-height
      // box in practice instead of a small grid-cell preview).
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : 90.0;
          return _box(width, width * 14 / 9);
        },
      );
    }
    return _box(widget.width ?? double.infinity, widget.height!);
  }
}

/// design-4.css section 2 — three dots rising in sequence, for short
/// shapeless waits (sending a message, following someone, a working button).
class LoadingDots extends StatefulWidget {
  const LoadingDots({super.key, this.color = AppColors.accent, this.size = 7});

  final Color color;
  final double size;

  @override
  State<LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<LoadingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.size + 6,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return Padding(
            padding: EdgeInsets.only(right: i < 2 ? 5 : 0),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final delay = i * 0.16 / 1.1;
                var t = (_controller.value - delay) % 1.0;
                if (t < 0) t += 1.0;
                // 0%,70%,100% -> y0 op.45 ; 35% -> y-5 op1 (dot-lift keyframes)
                final lift = t < 0.35
                    ? Curves.easeOut.transform(t / 0.35)
                    : t < 0.7
                        ? 1 - Curves.easeIn.transform((t - 0.35) / 0.35)
                        : 0.0;
                return Transform.translate(
                  offset: Offset(0, -5 * lift),
                  child: Opacity(
                    opacity: 0.45 + 0.55 * lift,
                    child: Container(
                      width: widget.size,
                      height: widget.size,
                      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
                    ),
                  ),
                );
              },
            ),
          );
        }),
      ),
    );
  }
}

/// design.css .spin — the one remaining legitimate spinner use: cold start /
/// full-screen waits with genuinely no shape to skeleton.
class AppSpinner extends StatelessWidget {
  const AppSpinner({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: const CircularProgressIndicator(
        strokeWidth: 2,
        color: AppColors.text,
        backgroundColor: AppColors.border,
      ),
    );
  }
}
