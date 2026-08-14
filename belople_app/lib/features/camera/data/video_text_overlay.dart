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

/// The part of the frame every viewer is actually going to see, as fractions of
/// the frame.
///
/// **The file is not what a viewer sees.** The composer letterboxes the clip —
/// the whole picture, edge to edge — while the feed paints it with
/// `BoxFit.cover` to fill the phone. Text dragged to the edge of the editor
/// therefore came back with its first letter shaved off, which is what was
/// reported on 2026-08-14.
///
/// The numbers are measured, not guessed. A probe in `video_slide.dart` on the
/// TECNO reported `slide=392.7x885.8 video=720x1280 cropX=0.1059 cropY=0.0000`:
/// the slide is the WHOLE screen, so a 9:16 clip loses **10.6% off each side**
/// and nothing at all top or bottom. Taller phones lose more — a 2.4:1 screen
/// loses 13% — so the sides here are 14%.
///
/// Top and bottom are not crop; they are the feed's own chrome painted over the
/// video: the tab row reaches 11% down, and the author, caption, sound line,
/// progress bar and nav cover everything below 80%.
///
/// Not "guidance": [overlayTopLeft] cannot place text outside this box, so the
/// promise is kept by the geometry rather than by the poster's judgement.
///
/// The right-hand column of action buttons (like, comment, share) sits over
/// roughly x 0.80–0.86 of the picture and is deliberately NOT excluded — text
/// there is still legible around them, the way it is on TikTok, and reserving
/// it would cost a fifth of the canvas.
const double kOverlaySafeLeft = 0.14;
const double kOverlaySafeRight = 0.14;
const double kOverlaySafeTop = 0.13;
const double kOverlaySafeBottom = 0.22;

/// The safe box in the frame's own coordinates.
Rect overlaySafeRect(Size frame) => Rect.fromLTRB(
      frame.width * kOverlaySafeLeft,
      frame.height * kOverlaySafeTop,
      frame.width * (1 - kOverlaySafeRight),
      frame.height * (1 - kOverlaySafeBottom),
    );

/// Text wraps at the safe box's width, so a long line cannot reach the part of
/// the frame that gets cropped away.
const double kOverlayMaxWidthFraction = 1 - kOverlaySafeLeft - kOverlaySafeRight;

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

/// How much room the block has to move in, INSIDE the safe box.
Size overlayFreeSpace(Size frame, Size block) {
  final safe = overlaySafeRect(frame);
  return Size(
    (safe.width - block.width).clamp(0.0, double.infinity),
    (safe.height - block.height).clamp(0.0, double.infinity),
  );
}

/// Where the block's top-left corner goes, given the frame and the block's own
/// measured size. `safe.topLeft + free * d` — see [VideoTextOverlay.dx]. Both
/// surfaces use it, and dx/dy of 0 and 1 are the safe box's edges, not the
/// frame's, so text cannot be placed where the feed would crop it.
Offset overlayTopLeft(VideoTextOverlay overlay, Size frame, Size block) {
  final safe = overlaySafeRect(frame);
  final free = overlayFreeSpace(frame, block);
  return Offset(safe.left + free.width * overlay.dx, safe.top + free.height * overlay.dy);
}

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
