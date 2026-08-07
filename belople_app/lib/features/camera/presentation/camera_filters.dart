import 'package:flutter/widgets.dart';

/// A colour-grade preset applied live to the camera preview. These are the
/// Flutter analogue of the web app's CSS `filter()` looks (index.html's
/// FILTERS) — expressed as 4x5 colour matrices, since that's what Flutter's
/// `ColorFilter.matrix` takes. The look shows on the preview; baking it into
/// the recorded file needs frame processing (ffmpeg), which is deferred, so
/// the saved take is currently the raw footage.
class CameraFilter {
  const CameraFilter(this.label, this.matrix);
  final String label;
  final List<double>? matrix; // null = no filter (Original)

  ColorFilter? get colorFilter => matrix == null ? null : ColorFilter.matrix(matrix!);
}

const List<CameraFilter> kCameraFilters = [
  CameraFilter('Original', null),
  CameraFilter('Warm', [
    1.12, 0, 0, 0, 8, //
    0, 1.02, 0, 0, 4, //
    0, 0, 0.90, 0, 0, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Cool', [
    0.92, 0, 0, 0, 0, //
    0, 1.00, 0, 0, 2, //
    0, 0, 1.12, 0, 8, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Vivid', [
    1.315, -0.286, -0.029, 0, 0, //
    -0.085, 1.114, -0.029, 0, 0, //
    -0.085, -0.286, 1.371, 0, 0, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Fade', [
    0.764, 0.215, 0.022, 0, -6, //
    0.064, 0.915, 0.022, 0, -6, //
    0.064, 0.215, 0.722, 0, -6, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Rose', [
    1.08, 0, 0, 0, 6, //
    0, 0.98, 0, 0, 0, //
    0, 0, 1.05, 0, 4, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Sepia', [
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0, //
    0.272, 0.534, 0.131, 0, 0, //
    0, 0, 0, 1, 0,
  ]),
  CameraFilter('Noir', [
    0.299, 0.587, 0.114, 0, 0, //
    0.299, 0.587, 0.114, 0, 0, //
    0.299, 0.587, 0.114, 0, 0, //
    0, 0, 0, 1, 0,
  ]),
];
