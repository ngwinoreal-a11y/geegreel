/// Which build this is, in words the person holding the phone can read out.
///
/// Set by CI at compile time (`--dart-define=BELOPLE_BUILD=…` in
/// `.github/workflows/build-apk.yml`), which assembles it from the version in
/// `pubspec.yaml`, the Actions run number and the commit's short SHA. Nothing
/// here is typed by hand, so it cannot drift from what was actually built —
/// which is exactly how Settings came to claim "Version 1.0.0" for months.
///
/// **Why it exists:** the APK ships from a permanent link that is overwritten
/// every build, so "is the one on my phone the newest?" was a question nobody
/// on a phone could answer. Now Settings answers it, and the answer can be
/// matched against `git log` without guessing.
///
/// A local `flutter run` passes no define, so it reads `dev build` — which is
/// the truth about a debug build too.
const String kBuildLabel = String.fromEnvironment(
  'BELOPLE_BUILD',
  defaultValue: 'dev build',
);
