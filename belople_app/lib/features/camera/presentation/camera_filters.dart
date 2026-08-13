import 'package:flutter/widgets.dart';

/// A colour-grade preset applied live to the camera preview. These are the
/// Flutter analogue of the web app's CSS `filter()` looks (index.html's
/// FILTERS) — expressed as 4x5 colour matrices, since that's what Flutter's
/// `ColorFilter.matrix` takes.
///
/// The recorder itself writes raw footage — Android's MediaRecorder takes the
/// sensor's frames, not the ones we tint on screen — so the look reaches the
/// published file through [ffmpegChain], burnt in by a pass on publish. The
/// matrix here is the single source of truth for both: change it once and the
/// viewfinder and the file move together, and neither can drift from the other.
class CameraFilter {
  const CameraFilter(this.label, this.matrix);
  final String label;
  final List<double>? matrix; // null = no filter (Original)

  ColorFilter? get colorFilter => matrix == null ? null : ColorFilter.matrix(matrix!);

  /// The same look as an FFmpeg filter chain, or null for Original (nothing to
  /// encode).
  ///
  /// One `colorchannelmixer` does the whole affine transform, constants and
  /// all. The constants are the awkward part — the mixer has no term for them —
  /// and the obvious answer, a `lutrgb` pass afterwards, is **wrong**: the
  /// mixer clamps its own output to 255 before the `lutrgb` ever sees it, so a
  /// look built from contrast (a gain above 1 paired with a negative constant,
  /// which is every one of these) came out visibly darker in the highlights
  /// than the same matrix on the viewfinder, where Skia clamps once at the end.
  /// Noir on a near-white pixel landed on 224 instead of 255.
  ///
  /// So the constants ride in on the alpha term instead. Alpha is forced opaque
  /// by `format=rgba` — video has no transparency — which makes `ra` a
  /// multiplier on a known 255, i.e. a constant, added inside the mixer and
  /// clamped exactly once, like Flutter's. Verified against real FFmpeg output
  /// in camera_filters_test.dart.
  String? get ffmpegChain {
    final m = matrix;
    if (m == null) return null;
    String n(double v) => v.toStringAsFixed(6);
    // Rows are r,g,b,a of five values each: three colour terms, an alpha term,
    // then the constant. Alpha arrives as 255, so the constant is folded into
    // the alpha term by dividing it by 255.
    String row(int i) => '${n(m[i])}:${n(m[i + 1])}:${n(m[i + 2])}:'
        '${n(m[i + 3] + m[i + 4] / 255)}';
    return 'format=rgba,colorchannelmixer='
        '${row(0)}:${row(5)}:${row(10)}:${row(15)}';
  }
}

// ---------------------------------------------------------------------------
// Grading primitives
//
// The looks below are BUILT from these rather than written out as twenty loose
// numbers each. Hand-tuned matrices were how the old presets ended up washing
// out highlights and shifting skin tones: "make it warmer" was done by
// multiplying the red channel, which brightens the frame as a side effect and
// has no way to say "and hold the contrast". Composed operations say what they
// mean, so a look can be adjusted one property at a time.
// ---------------------------------------------------------------------------

// Rec.709 luma weights — how bright each channel actually looks to the eye.
// Rec.601's (0.299/0.587/0.114) is the older set and turns skin muddy in
// black-and-white.
const double _lumaR = 0.2126, _lumaG = 0.7152, _lumaB = 0.0722;

const List<double> _identity = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0,
];

/// [s] = 0 is greyscale, 1 unchanged, >1 more colourful. Pulls each channel
/// towards (or away from) the pixel's own brightness, so nothing shifts hue.
List<double> _saturation(double s) {
  final r = (1 - s) * _lumaR, g = (1 - s) * _lumaG, b = (1 - s) * _lumaB;
  return [
    r + s, g, b, 0, 0, //
    r, g + s, b, 0, 0, //
    r, g, b + s, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}

/// Contrast pivoted on mid-grey. The pivot is the point: scaling the channels
/// alone raises contrast AND brightness together, which is what blew out faces
/// in the old Vivid.
List<double> _contrast(double c) {
  final o = 127.5 * (1 - c);
  return [
    c, 0, 0, 0, o, //
    0, c, 0, 0, o, //
    0, 0, c, 0, o, //
    0, 0, 0, 1, 0,
  ];
}

/// Per-channel gain (multiplies, so it bites hardest in the highlights) and
/// lift (adds, so it bites hardest in the shadows). Warmth is gain; a matte,
/// faded black is lift.
List<double> _channels({
  double r = 1,
  double g = 1,
  double b = 1,
  double rLift = 0,
  double gLift = 0,
  double bLift = 0,
}) =>
    [
      r, 0, 0, 0, rLift, //
      0, g, 0, 0, gLift, //
      0, 0, b, 0, bLift, //
      0, 0, 0, 1, 0,
    ];

/// [a] applied to the result of [b] — i.e. b happens first.
List<double> _compose(List<double> a, List<double> b) {
  final out = List<double>.filled(20, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 4; col++) {
      var sum = 0.0;
      for (var k = 0; k < 4; k++) {
        sum += a[row * 5 + k] * b[k * 5 + col];
      }
      out[row * 5 + col] = sum;
    }
    var constant = a[row * 5 + 4];
    for (var k = 0; k < 4; k++) {
      constant += a[row * 5 + k] * b[k * 5 + 4];
    }
    out[row * 5 + 4] = constant;
  }
  return out;
}

/// Collapses a list of operations, applied in the order written, into the one
/// matrix both the preview and FFmpeg get.
List<double> _stack(List<List<double>> steps) =>
    steps.fold(_identity, (acc, step) => _compose(step, acc));

/// The eight looks, in the order they appear under the viewfinder. Not `const`
/// any more — each matrix is now composed at startup rather than typed out —
/// but it is built once and never mutated.
final List<CameraFilter> kCameraFilters = [
  const CameraFilter('Original', null),

  // Golden-hour light: warmth carried by gain so it lands in the highlights,
  // a touch more colour, and enough contrast that the warmth reads as light
  // rather than as a haze over the frame.
  CameraFilter('Warm', _stack([
    _contrast(1.06),
    _saturation(1.12),
    _channels(r: 1.07, g: 1.01, b: 0.93, rLift: 3, bLift: -2),
  ])),

  // Overcast daylight cleaned up: blue in the highlights, a cool lift in the
  // shadows, and the red pulled back only slightly so skin doesn't go grey.
  CameraFilter('Cool', _stack([
    _contrast(1.06),
    _saturation(1.06),
    _channels(r: 0.96, g: 1.0, b: 1.09, bLift: 5),
  ])),

  // Punchy, for daylight and movement. 1.45 saturation is a lot, which is the
  // point of the preset, but the contrast stays modest — pushing both is what
  // used to clip faces to flat orange.
  CameraFilter('Vivid', _stack([
    _contrast(1.13),
    _saturation(1.45),
  ])),

  // Matte film: lifted, slightly cool blacks and low contrast. The lift has to
  // come after the contrast or the pivot pulls it straight back down.
  CameraFilter('Fade', _stack([
    _contrast(0.82),
    _saturation(0.86),
    _channels(rLift: 14, gLift: 15, bLift: 20),
  ])),

  // Soft and flattering rather than pink: a gentle rose gain, a hint of lift to
  // open the shadows, and contrast held just under 1 so skin stays smooth.
  CameraFilter('Rose', _stack([
    _contrast(0.97),
    _saturation(1.08),
    _channels(r: 1.07, g: 0.99, b: 1.04, rLift: 7, gLift: 2, bLift: 5),
  ])),

  // Desaturate first, then tone — the classic sepia matrix bakes both into one
  // step and can't be adjusted without redoing the whole thing.
  CameraFilter('Sepia', _stack([
    _contrast(1.05),
    _saturation(0),
    _channels(r: 1.14, g: 1.0, b: 0.80, rLift: 8, bLift: -4),
  ])),

  // High-contrast black and white, on Rec.709 weights so skin keeps its
  // separation from the background instead of flattening into it.
  CameraFilter('Noir', _stack([
    _contrast(1.24),
    _saturation(0),
  ])),
];
