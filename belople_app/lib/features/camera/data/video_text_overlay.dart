import 'package:flutter/material.dart';

/// One piece of text the poster put on their clip.
///
/// Position and size are fractions of the FRAME, never pixels. The preview on
/// the phone is a few hundred logical points wide and the file it burns into is
/// 1080 or more, so anything stored in pixels lands somewhere else in the
/// finished video than it did under the finger that placed it. Fractions are
/// the only thing the two surfaces agree on.
class VideoTextOverlay {
  VideoTextOverlay({
    required this.id,
    this.text = '',
    this.dx = 0.5,
    this.dy = 0.5,
    this.scale = 1.0,
    this.colorIndex = 0,
  });

  final String id;
  String text;

  /// How far along the FREE space the block sits, 0..1 — the same rule
  /// Flutter's [Alignment] uses. 0 puts its left (or top) edge on the frame's
  /// edge, 1 puts its right (or bottom) edge there, 0.5 centres it.
  ///
  /// Deliberately not "the centre of the block": with a centre, a wide line at
  /// dx = 0.05 hangs half of itself off the side of the video, and the poster
  /// only finds out after the render. Along-the-free-space cannot leave the
  /// frame, and it is one expression — `free * d` — in both the preview and the
  /// PNG, which is the only way the two stay honest with each other.
  double dx;
  double dy;

  /// Multiplies [kOverlayBaseFontFraction]. Clamped by the size slider.
  double scale;

  int colorIndex;

  Color get color => kOverlayTextColors[colorIndex % kOverlayTextColors.length];

  bool get isEmpty => text.trim().isEmpty;

  VideoTextOverlay copyWith({String? text, double? dx, double? dy, double? scale, int? colorIndex}) =>
      VideoTextOverlay(
        id: id,
        text: text ?? this.text,
        dx: dx ?? this.dx,
        dy: dy ?? this.dy,
        scale: scale ?? this.scale,
        colorIndex: colorIndex ?? this.colorIndex,
      );
}

/// White and black first: those are the two that read on almost any footage,
/// and the amber after them is the app's own accent.
const kOverlayTextColors = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFF000000),
  Color(0xFFFFC043),
  Color(0xFFFF3B5C),
  Color(0xFFFF7A00),
  Color(0xFFFFE94E),
  Color(0xFF4CD964),
  Color(0xFF25D0C0),
  Color(0xFF3B9CFF),
  Color(0xFF8B5CF6),
  Color(0xFFFF6EC7),
];

/// Base text size as a fraction of the frame's WIDTH. Everything about a text
/// overlay is measured against the width so that a portrait clip and a square
/// one put the same text at the same visual size.
const double kOverlayBaseFontFraction = 0.058;

/// Text wraps at this fraction of the frame width, leaving a margin the same
/// way TikTok's does — text running edge to edge reads as broken.
const double kOverlayMaxWidthFraction = 0.86;

const double kOverlayMinScale = 0.5;
const double kOverlayMaxScale = 2.6;

/// The ONE style a text overlay is ever drawn in.
///
/// Both surfaces call this: the editor builds a [Text] with it, the render
/// builds a [TextPainter] with it, and nothing differs between them but
/// [frameWidth] — the editor passes its own width in logical points, the render
/// passes the video's width in pixels. Every measurement below is a fraction of
/// that width, so the same overlay comes out the same size relative to the
/// frame on a 360-point preview and a 1080-pixel file.
///
/// It is the arrangement the colour filters already use, for the same reason:
/// one definition, two surfaces, no chance of them drifting apart.
TextStyle overlayTextStyle(VideoTextOverlay overlay, double frameWidth) {
  final fontSize = kOverlayBaseFontFraction * frameWidth * overlay.scale;
  return TextStyle(
    color: overlay.color,
    fontSize: fontSize,
    fontWeight: FontWeight.w800,
    height: 1.18,
    letterSpacing: 0.2,
    // A shadow, always. White text over a bright sky and black text over a dark
    // room both vanish without one, and someone picking a colour they like
    // cannot be asked to think about the footage underneath it.
    shadows: [
      Shadow(
        color: Colors.black.withValues(alpha: 0.55),
        blurRadius: fontSize * 0.28,
        offset: Offset(0, fontSize * 0.03),
      ),
    ],
  );
}

/// The overlay laid out and ready to paint, shrink-wrapped to its longest line.
///
/// `maxLines` and the wrap width are part of the layout, so they live here
/// rather than at each call site — a [Text] in the editor allowed seven lines
/// while the render allowed six would place every multi-line overlay somewhere
/// slightly different.
TextPainter overlayPainter(VideoTextOverlay overlay, double frameWidth) => TextPainter(
      text: TextSpan(text: overlay.text, style: overlayTextStyle(overlay, frameWidth)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: kOverlayMaxLines,
      ellipsis: '…',
    )..layout(maxWidth: frameWidth * kOverlayMaxWidthFraction);

/// Where the block's top-left corner goes, given the frame and the block's own
/// measured size. `free * d` — see [VideoTextOverlay.dx]. Both surfaces use it,
/// and it is the same rule as `Alignment(dx * 2 - 1, dy * 2 - 1)`.
Offset overlayTopLeft(VideoTextOverlay overlay, Size frame, Size block) => Offset(
      (frame.width - block.width).clamp(0.0, double.infinity) * overlay.dx,
      (frame.height - block.height).clamp(0.0, double.infinity) * overlay.dy,
    );

const int kOverlayMaxLines = 6;

/// Draws a whole set of overlays onto a frame of [size].
///
/// The composer's preview paints with it and the PNG that FFmpeg burns in is
/// painted with it, so "what the preview showed" and "what the file carries"
/// are not two implementations that have to be kept in step — they are one
/// piece of code run at two sizes.
class OverlayLayerPainter extends CustomPainter {
  const OverlayLayerPainter(this.overlays);

  final List<VideoTextOverlay> overlays;

  @override
  void paint(Canvas canvas, Size size) {
    for (final overlay in overlays) {
      if (overlay.isEmpty) continue;
      final painter = overlayPainter(overlay, size.width);
      painter.paint(canvas, overlayTopLeft(overlay, size, painter.size));
    }
  }

  @override
  bool shouldRepaint(OverlayLayerPainter old) => true;
}
