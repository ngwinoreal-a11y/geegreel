import 'dart:io';

import 'package:belople_app/features/camera/presentation/camera_filters.dart';
import 'package:flutter_test/flutter_test.dart';

/// The whole promise of the filter feature is that the look on the viewfinder
/// and the look burnt into the published file are the same look. They are
/// computed by two completely different engines — Flutter's `ColorFilter.matrix`
/// on screen, FFmpeg's `colorchannelmixer`/`lutrgb` on the file — from one
/// matrix, and nothing but arithmetic keeps them together.
///
/// So this runs the real FFmpeg over real pixels and checks it lands where the
/// matrix says it should. It catches the things reading the code cannot: a
/// transposed compose(), colorchannelmixer's parameter order, an offset applied
/// before the mix instead of after.
///
/// Skipped when ffmpeg isn't on PATH (CI builds the APK, it doesn't grade
/// video) — a skipped check says so, which a silently-passing one would not.
void main() {
  final ffmpeg = _findFfmpeg();

  group('CameraFilter', () {
    test('every look but Original produces an FFmpeg chain', () {
      expect(kCameraFilters.first.label, 'Original');
      expect(kCameraFilters.first.ffmpegChain, isNull);
      for (final f in kCameraFilters.skip(1)) {
        expect(f.ffmpegChain, isNotNull, reason: '${f.label} has no chain');
        expect(f.matrix, hasLength(20), reason: '${f.label} is not a 4x5 matrix');
      }
    });

    test('Noir is true greyscale', () {
      // Identical colour rows: whatever goes in, r, g and b come out equal.
      final m = kCameraFilters.firstWhere((f) => f.label == 'Noir').matrix!;
      for (var col = 0; col < 3; col++) {
        expect(m[col], closeTo(m[5 + col], 1e-9), reason: 'row g differs at $col');
        expect(m[col], closeTo(m[10 + col], 1e-9), reason: 'row b differs at $col');
      }
    });

    test('Sepia is one tone at every brightness', () {
      // Sepia is greyscale THEN tinted, so its rows are not identical — they
      // are multiples of each other. That is what makes it a single tone: the
      // ratio between the channels, and so the hue, is the same for every
      // input, and only the brightness moves.
      final m = kCameraFilters.firstWhere((f) => f.label == 'Sepia').matrix!;
      final gainG = m[5] / m[0], gainB = m[10] / m[0];
      for (var col = 0; col < 3; col++) {
        expect(m[5 + col] / m[col], closeTo(gainG, 1e-9), reason: 'row g is not proportional at $col');
        expect(m[10 + col] / m[col], closeTo(gainB, 1e-9), reason: 'row b is not proportional at $col');
      }
      // And it is a warm tone, not a cold one — red above green above blue.
      expect(gainG, lessThan(1));
      expect(gainB, lessThan(gainG));
    });

    test('alpha is left alone by every look', () {
      for (final f in kCameraFilters.skip(1)) {
        final m = f.matrix!;
        expect(m.sublist(15, 20), [0, 0, 0, 1, 0], reason: '${f.label} touches alpha');
      }
    });
  });

  group('FFmpeg renders what the matrix predicts', () {
    // Mid-tones, a skin-ish tone, a near-black and a near-white: the four
    // places a grade is most likely to be wrong, and where clipping shows.
    const probes = [
      [128, 128, 128],
      [205, 160, 130],
      [18, 22, 30],
      [240, 235, 225],
    ];

    for (final filter in kCameraFilters.skip(1)) {
      test('${filter.label} matches its matrix', () async {
        for (final probe in probes) {
          final actual = await _renderThroughFfmpeg(ffmpeg!, filter.ffmpegChain!, probe);
          final expected = _applyMatrix(filter.matrix!, probe);
          for (var c = 0; c < 3; c++) {
            expect(
              actual[c],
              closeTo(expected[c], 3),
              reason: '${filter.label} on rgb$probe: channel $c — '
                  'FFmpeg gave $actual, the matrix says $expected',
            );
          }
        }
      });
    }
  }, skip: ffmpeg == null ? 'ffmpeg is not on PATH' : false);
}

String? _findFfmpeg() {
  try {
    final probe = Process.runSync(Platform.isWindows ? 'where' : 'which', ['ffmpeg']);
    if (probe.exitCode != 0) return null;
    final first = (probe.stdout as String).split('\n').first.trim();
    return first.isEmpty ? null : first;
  } on ProcessException {
    return null;
  }
}

/// What Flutter's `ColorFilter.matrix` does to one pixel: multiply, add, and
/// clamp ONCE, at the end. The single clamp is the whole point of the
/// comparison — an intermediate one is what the alpha-term trick exists to
/// avoid. Video is opaque, so alpha is 255.
List<double> _applyMatrix(List<double> m, List<int> rgb) {
  final out = <double>[];
  for (var row = 0; row < 3; row++) {
    final v = m[row * 5] * rgb[0] +
        m[row * 5 + 1] * rgb[1] +
        m[row * 5 + 2] * rgb[2] +
        m[row * 5 + 3] * 255 +
        m[row * 5 + 4];
    out.add(v.clamp(0, 255));
  }
  return out;
}

/// Paints one flat colour, runs [chain] over it, and reads the pixel back.
Future<List<int>> _renderThroughFfmpeg(String ffmpeg, String chain, List<int> rgb) async {
  final hex = rgb.map((c) => c.toRadixString(16).padLeft(2, '0')).join();
  final result = await Process.run(ffmpeg, [
    '-v', 'error',
    '-f', 'lavfi', '-i', 'color=c=0x$hex:s=16x16:d=1,format=rgb24',
    '-vf', chain,
    '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
  ], stdoutEncoding: null);

  if (result.exitCode != 0) {
    fail('ffmpeg failed on "$chain": ${result.stderr}');
  }
  final bytes = result.stdout as List<int>;
  expect(bytes, isNotEmpty, reason: 'ffmpeg produced no pixels for "$chain"');
  // Read the middle pixel, well away from any edge handling.
  final offset = (16 * 8 + 8) * 3;
  return [bytes[offset], bytes[offset + 1], bytes[offset + 2]];
}
