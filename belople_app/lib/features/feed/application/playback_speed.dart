import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The playback speed applied to the currently-playing feed video. Set from
/// the video "•••" sheet's Speed option; every VideoSlide watches it and calls
/// `setPlaybackSpeed` on its controller. Resets to 1.0 by default.
final playbackSpeedProvider = StateProvider<double>((ref) => 1.0);

/// The speeds the Speed picker cycles through, matching the web app.
const List<double> kPlaybackSpeeds = [0.5, 1.0, 1.5, 2.0];
