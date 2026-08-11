import 'package:flutter/material.dart';

/// Belople's loading mark: three dots that rise and fall in sequence, carrying
/// the logo's own gradient — orange at the top of the mark through to magenta
/// at its foot. Used wherever the app is fetching on the user's behalf, so
/// waiting looks like the product rather than a stock spinner.
class BrandRefreshDots extends StatefulWidget {
  const BrandRefreshDots({super.key, this.size = 9, this.spacing = 6});
  final double size;
  final double spacing;

  @override
  State<BrandRefreshDots> createState() => _BrandRefreshDotsState();
}

class _BrandRefreshDotsState extends State<BrandRefreshDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  // Sampled from assets/icon/belople_mark.jpg — the same three-stroke gradient,
  // one colour per dot, left to right.
  static const _colors = [Color(0xFFFF7A18), Color(0xFFFF3D68), Color(0xFFF5147F)];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(3, (i) {
            // Each dot trails the one before it by a third of a cycle, which is
            // what reads as a wave rather than three things blinking.
            final t = (_c.value + i / 3) % 1.0;
            final lift = Curves.easeInOut.transform(t < 0.5 ? t * 2 : (1 - t) * 2);
            return Padding(
              padding: EdgeInsets.only(
                left: i == 0 ? 0 : widget.spacing,
                bottom: lift * widget.size,
              ),
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: _colors[i],
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Pull-to-refresh wearing the Belople dots instead of Material's spinner.
///
/// RefreshIndicator can't have its own indicator swapped out, so this hides it
/// (zero displacement, transparent) and draws the dots over the top while the
/// gesture is in progress — the standard behaviour, the app's face.
class BrandRefresh extends StatefulWidget {
  const BrandRefresh({super.key, required this.onRefresh, required this.child});
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<BrandRefresh> createState() => _BrandRefreshState();
}

class _BrandRefreshState extends State<BrandRefresh> {
  bool _busy = false;

  /// How far the list has been dragged past its top. Tracked so the dots appear
  /// DURING the pull, not only once the refresh has started — hiding Material's
  /// ring without putting anything in its place meant a pull produced no
  /// feedback at all, which reads as "refresh doesn't work".
  double _pull = 0;

  Future<void> _run() async {
    setState(() { _busy = true; _pull = 0; });
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _showDots => _busy || _pull > 12;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is OverscrollNotification && n.overscroll < 0) {
              setState(() => _pull -= n.overscroll);
            } else if (n is ScrollEndNotification && _pull != 0) {
              setState(() => _pull = 0);
            }
            return false;
          },
          child: RefreshIndicator(
            onRefresh: _run,
            // Material's ring is hidden rather than removed: RefreshIndicator
            // owns the gesture, the overscroll physics and the release
            // threshold, and reimplementing those to change one glyph would be
            // a lot of surface area for no gain. The dots above are what the
            // user actually sees.
            color: Colors.transparent,
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: widget.child,
          ),
        ),
        if (_showDots)
          Positioned(
            top: 14,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const BrandRefreshDots(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
