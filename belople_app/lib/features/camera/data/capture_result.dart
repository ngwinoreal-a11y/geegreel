/// What the in-app camera hands back to whoever opened it.
///
/// This used to be a string — `'video:/path/to.mp4'`, parsed with
/// `substring(6)` at three call sites. It stopped being one when the chosen
/// colour look had to travel with the clip: the look is an index, the path is
/// a path, and packing a second field into that string meant picking a
/// separator no filename could ever contain. There isn't one worth betting on.
///
/// Only these two kinds are ever popped. Text mode publishes from the camera
/// itself and pops nothing, and backing out pops null.
enum CaptureKind { video, photo }

class CaptureResult {
  const CaptureResult.video(this.path, {this.filterIndex = 0})
      : kind = CaptureKind.video;

  const CaptureResult.photo(this.path)
      : kind = CaptureKind.photo,
        filterIndex = 0;

  final CaptureKind kind;

  /// The recorded, captured or picked file.
  final String path;

  /// Index into `kCameraFilters` of the look chosen on the viewfinder — 0 is
  /// Original. It has to travel with the clip because the recorded file is raw
  /// footage: Android's MediaRecorder writes the sensor's frames, not the
  /// tinted ones on screen, so the look is burnt in later, on publish.
  final int filterIndex;
}
