import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import 'camera_filters.dart';

/// In-app camera modelled on the reference (Instagram/TikTok style): mode tabs
/// Short / Public / Text, a max-duration picker for Short, live colour filters,
/// flip, flash, and gallery access.
///
/// Pops a result the caller routes into the composer:
///   `video:<path>`  a recorded/gallery video    (Short)
///   `photo:<path>`  a captured/gallery photo     (Public)
///   'text'          switch to a text-only post   (Text)
///   'compose'       open the composer with nothing (fallback)
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

enum _CamMode { short, public, text }

class _CameraCaptureScreenState extends State<CameraCaptureScreen> with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _initializing = true;
  String? _error;

  bool _recording = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  FlashMode _flashMode = FlashMode.off;
  int _filterIndex = 0;

  _CamMode _mode = _CamMode.short;
  int _maxSeconds = 60;
  final _picker = ImagePicker();

  // Max-record options shown as pills in Short mode.
  // 3 minutes was dropped: at phone bitrates that's a very large upload for
  // both the poster's data and everyone who watches it. 2 minutes is the
  // ceiling that still covers a long take.
  static const _durations = [15, 60, 120];
  String _durationLabel(int s) => s < 60 ? '${s}s' : '${s ~/ 60}m';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setup();
  }

  Future<void> _setup() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() { _initializing = false; _error = 'No camera found on this device'; });
        return;
      }
      await _startController(0);
    } catch (_) {
      if (mounted) setState(() { _initializing = false; _error = "Couldn't open the camera"; });
    }
  }

  Future<void> _startController(int index) async {
    // Release the previous camera BEFORE opening the next one. Holding two
    // controllers at once is what made a flip-to-front come up black.
    final previous = _controller;
    _controller = null;
    await previous?.dispose();

    final controller = CameraController(_cameras[index], ResolutionPreset.high, enableAudio: true);
    _cameraIndex = index;
    try {
      await controller.initialize();
    } catch (_) {
      if (mounted) setState(() { _initializing = false; _error = "Couldn't start the camera"; });
      return;
    }
    try {
      await controller.setFlashMode(_flashMode);
    } catch (_) {}
    if (!mounted) { controller.dispose(); return; }
    setState(() { _controller = controller; _initializing = false; });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _startController(_cameraIndex);
    }
  }

  // ----- capture actions -----

  Future<void> _onCapture() async {
    if (_mode == _CamMode.public) {
      await _takePhoto();
    } else {
      await _toggleRecording();
    }
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final file = await controller.takePicture();
      if (mounted) context.pop('photo:${file.path}');
    } catch (_) {}
  }

  Future<void> _toggleRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_recording) {
      _timer?.cancel();
      try {
        final file = await controller.stopVideoRecording();
        if (mounted) {
          setState(() => _recording = false);
          context.pop('video:${file.path}');
        }
      } catch (_) {
        if (mounted) setState(() => _recording = false);
      }
    } else {
      try {
        await controller.startVideoRecording();
      } catch (_) {
        return;
      }
      setState(() { _recording = true; _elapsed = Duration.zero; });
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(milliseconds: 200));
        if (_elapsed.inSeconds >= _maxSeconds) _toggleRecording();
      });
    }
  }

  Future<void> _pickFromGallery() async {
    if (_mode == _CamMode.short) {
      final v = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: Duration(seconds: _maxSeconds));
      if (v != null && mounted) context.pop('video:${v.path}');
    } else {
      final p = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (p != null && mounted) context.pop('photo:${p.path}');
    }
  }

  Future<void> _flip() async {
    if (_cameras.length < 2 || _recording) return;
    setState(() => _initializing = true);
    await _startController((_cameraIndex + 1) % _cameras.length);
  }

  Future<void> _cycleFlash() async {
    final controller = _controller;
    if (controller == null) return;
    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };
    setState(() => _flashMode = next);
    try { await controller.setFlashMode(next); } catch (_) {}
  }

  IconData get _flashIcon => switch (_flashMode) {
        FlashMode.off => Icons.flash_off,
        FlashMode.auto => Icons.flash_auto,
        _ => Icons.flash_on,
      };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final filter = kCameraFilters[_filterIndex];
    final ready = controller != null && controller.value.isInitialized && !_initializing;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _error != null
            ? _CameraError(message: _error!, onClose: () => context.pop())
            : _mode == _CamMode.text
                ? _TextComposePrompt(onContinue: () => context.pop('text'), onClose: () => context.pop(), tabs: _modeTabs())
                : _mode == _CamMode.public
                    // Public posts are photos — no camera, just the phone's
                    // gallery (opens straight away, matching the reference).
                    ? _GalleryPrompt(onPick: _pickFromGallery, onClose: () => context.pop(), tabs: _modeTabs())
                    : Stack(
                    fit: StackFit.expand,
                    children: [
                      if (ready)
                        Center(
                          child: filter.colorFilter == null
                              ? CameraPreview(controller)
                              : ColorFiltered(colorFilter: filter.colorFilter!, child: CameraPreview(controller)),
                        )
                      else
                        const Center(child: CircularProgressIndicator(color: Colors.white)),

                      // Top: close, flip. There was an "Add sound" pill here
                      // that did nothing — its onTap was empty, because the
                      // sound picker lives in the composer. A control that
                      // looks tappable and isn't is worse than no control.
                      Positioned(
                        top: 8, left: 8, right: 8,
                        child: Row(
                          children: [
                            _RoundIcon(icon: Icons.close, onTap: () => context.pop()),
                            const Spacer(),
                            _RoundIcon(icon: Icons.cameraswitch, onTap: _flip),
                          ],
                        ),
                      ),

                      // Right rail: flash. The filters toggle used to live here
                      // too — the looks are on the shelf above the shutter now,
                      // so there is nothing left to toggle.
                      Positioned(
                        top: 64, right: 8,
                        child: Column(children: [
                          _RoundIcon(icon: _flashIcon, onTap: _cycleFlash),
                        ]),
                      ),

                      if (_recording)
                        Positioned(
                          top: 12, left: 0, right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle)),
                                const SizedBox(width: 6),
                                Text(_fmt(_elapsed), style: AppTypography.sans(fontSize: 13, color: Colors.white)),
                              ]),
                            ),
                          ),
                        ),

                      // Bottom controls: duration pills, the record row with the
                      // looks either side of the shutter, then the mode tabs
                      // with the gallery beside them.
                      Positioned(
                        left: 0, right: 0, bottom: 20,
                        child: Column(
                          children: [
                            if (_mode == _CamMode.short && !_recording)
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (final s in _durations)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () => setState(() => _maxSeconds = s),
                                        child: Text(_durationLabel(s),
                                            style: AppTypography.sans(
                                              // Legible at arm's length, but no
                                              // bigger: at 20px these read as
                                              // the loudest thing on a screen
                                              // whose whole job is the picture
                                              // behind them. The shadow does
                                              // the work of standing out.
                                              fontSize: _maxSeconds == s ? 15 : 13.5,
                                              fontWeight: _maxSeconds == s ? FontWeight.w800 : FontWeight.w600,
                                              color: _maxSeconds == s ? AppColors.accent : Colors.white70,
                                            ).copyWith(
                                              // Readable over a bright
                                              // viewfinder, not just a dark one.
                                              shadows: const [Shadow(color: Colors.black87, blurRadius: 6)],
                                            )),
                                      ),
                                    ),
                                ],
                              ),
                            const SizedBox(height: 14),
                            // The record row. The looks run straight through it
                            // — two either side of the shutter, which is what
                            // the width allows at this size — and scroll left
                            // and right for the rest. Above the shutter they
                            // were a separate shelf and read as a menu; in line
                            // with it they read as part of taking the shot.
                            SizedBox(
                              height: 92,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Four at a time — two either side of a gap
                                  // the shutter sits in — and swipe for the
                                  // next four. A plain scrolling strip put one
                                  // look permanently underneath the shutter,
                                  // where it could be neither seen nor tapped;
                                  // paging keeps the middle empty on purpose.
                                  if (!_recording && ready)
                                    PageView.builder(
                                      itemCount: (kCameraFilters.length / 4).ceil(),
                                      itemBuilder: (context, page) {
                                        Widget slot(int j) {
                                          final i = page * 4 + j;
                                          if (i >= kCameraFilters.length) {
                                            // Keeps the last page's spacing
                                            // identical to a full one.
                                            return const SizedBox(width: 68);
                                          }
                                          return _FilterThumb(
                                            filter: kCameraFilters[i],
                                            selected: i == _filterIndex,
                                            onTap: () => setState(() => _filterIndex = i),
                                          );
                                        }

                                        return Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                          children: [
                                            slot(0),
                                            slot(1),
                                            const SizedBox(width: 84), // the shutter's seat
                                            slot(2),
                                            slot(3),
                                          ],
                                        );
                                      },
                                    ),
                                  // The shutter sits ON the strip, not in it, so
                                  // it stays put while the looks slide past.
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: _onCapture,
                                    child: Container(
                                      width: 84, height: 84,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.black.withValues(alpha: 0.35),
                                        border: Border.all(color: Colors.white, width: 4),
                                      ),
                                      child: Center(
                                        child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 200),
                                          width: _recording ? 30 : 64,
                                          height: _recording ? 30 : 64,
                                          decoration: BoxDecoration(
                                            color: _mode == _CamMode.public ? Colors.white : AppColors.danger,
                                            borderRadius: BorderRadius.circular(_recording ? 8 : 40),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Mode tabs centred, gallery pinned to the left of
                            // them — the shape every camera uses, and it frees
                            // the record row entirely for the looks.
                            SizedBox(
                              height: 52,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  _modeTabs(),
                                  Positioned(left: 18, child: _GalleryButton(onTap: _pickFromGallery)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _modeTabs() {
    Widget tab(String label, _CamMode m) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _mode = m),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(label,
                style: AppTypography.sans(
                  // These are the one control you use on every single visit —
                  // which kind of thing am I making — so they get the size to
                  // match, and are hit at a glance rather than aimed at.
                  fontSize: _mode == m ? 19 : 17,
                  fontWeight: _mode == m ? FontWeight.w800 : FontWeight.w600,
                  color: _mode == m ? AppColors.accent : Colors.white70,
                ).copyWith(shadows: const [Shadow(color: Colors.black87, blurRadius: 6)])),
          ),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [tab('Short', _CamMode.short), tab('Public', _CamMode.public), tab('Text', _CamMode.text)],
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// The Text mode surface: a big prompt to write a public text post; Continue
/// hands off to the composer's text mode.
class _TextComposePrompt extends StatelessWidget {
  const _TextComposePrompt({required this.onContinue, required this.onClose, required this.tabs});
  final VoidCallback onContinue;
  final VoidCallback onClose;
  final Widget tabs;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 8, left: 8,
          child: _RoundIcon(icon: Icons.close, onTap: onClose),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.article_outlined, color: Colors.white38, size: 60),
                const SizedBox(height: 16),
                Text('Write a public post', style: AppTypography.display(fontSize: 20, color: Colors.white)),
                const SizedBox(height: 8),
                Text('Share a thought or story — no photo needed.',
                    textAlign: TextAlign.center,
                    style: AppTypography.sans(fontSize: 14, color: Colors.white54)),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(onPressed: onContinue, child: const Text('Continue')),
                ),
              ],
            ),
          ),
        ),
        Positioned(left: 0, right: 0, bottom: 20, child: tabs),
      ],
    );
  }
}

/// The Public mode surface: no camera — a clean gallery prompt that opens the
/// phone's photos straight away (and can be reopened), matching the reference
/// where a Public post is a picture chosen from the gallery.
class _GalleryPrompt extends StatefulWidget {
  const _GalleryPrompt({required this.onPick, required this.onClose, required this.tabs});
  final Future<void> Function() onPick;
  final VoidCallback onClose;
  final Widget tabs;

  @override
  State<_GalleryPrompt> createState() => _GalleryPromptState();
}

class _GalleryPromptState extends State<_GalleryPrompt> {
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    // Open the gallery immediately when Public mode is entered.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await widget.onPick();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(top: 8, left: 8, child: _RoundIcon(icon: Icons.close, onTap: widget.onClose)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A little gallery-grid glyph so the surface reads as "photos".
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: GridView.count(
                    padding: const EdgeInsets.all(14),
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    physics: const NeverScrollableScrollPhysics(),
                    children: List.generate(4, (_) => Container(
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    )),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Choose a photo', style: AppTypography.display(fontSize: 20, color: Colors.white)),
                const SizedBox(height: 8),
                Text('Pick a picture from your phone to post to Public.',
                    textAlign: TextAlign.center,
                    style: AppTypography.sans(fontSize: 14, color: Colors.white54)),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _opening ? null : _open,
                    icon: const Icon(Icons.photo_library_outlined, size: 20),
                    label: Text(_opening ? 'Opening gallery…' : 'Open gallery'),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(left: 0, right: 0, bottom: 20, child: widget.tabs),
      ],
    );
  }
}

/// One look on the shelf: a round swatch showing what that look does to skin
/// and to the light behind it, so the choice is made by looking rather than by
/// reading a word and guessing what "Vivid" will do.
///
/// A swatch, and NOT a live thumbnail of the viewfinder. Drawing the camera
/// texture eight times over and putting a different ColorFilter on each one
/// bled through to the main preview — the whole viewfinder came out greyscale,
/// wearing the last filter in the list. One camera surface can only really be
/// composited once, so the strip paints its own colours instead.
class _FilterThumb extends StatelessWidget {
  const _FilterThumb({
    required this.filter,
    required this.selected,
    required this.onTap,
  });
  final CameraFilter filter;
  final bool selected;
  final VoidCallback onTap;

  /// Light, mid and shadow off a face — the three tones a look actually has to
  /// answer for. A flat square of colour tells you far less.
  static const _swatch = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF6E3CC), Color(0xFFC98A55), Color(0xFF4A3325)],
    stops: [0.0, 0.55, 1.0],
  );

  @override
  Widget build(BuildContext context) {
    const face = DecoratedBox(decoration: BoxDecoration(gradient: _swatch));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            // Sized to the shutter it sits beside, which is also what limits
            // the row to two either side — the number asked for.
            width: 68,
            height: 68,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // The selected look wears the brand ring; the rest a hairline
              // that keeps them visible against a bright viewfinder.
              border: Border.all(
                color: selected ? AppColors.accent : Colors.white54,
                width: selected ? 3 : 1.2,
              ),
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8)],
            ),
            child: ClipOval(
              child: filter.colorFilter == null
                  ? face
                  : ColorFiltered(colorFilter: filter.colorFilter!, child: face),
            ),
          ),
          const SizedBox(height: 4),
          Text(filter.label,
              style: AppTypography.sans(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.accent : Colors.white,
              ).copyWith(shadows: const [Shadow(color: Colors.black87, blurRadius: 5)])),
        ],
      ),
    );
  }
}

/// The way back to your own footage. Pink, and wearing the brand gradient
/// rather than the grey outlined square it was — it is the only control on
/// this screen that leaves the camera, so it should not look like a setting.
class _GalleryButton extends StatelessWidget {
  const _GalleryButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFE2C55), Color(0xFFEE2A7B), Color(0xFF6228D7)],
          ),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 3))],
        ),
        child: const Icon(Icons.perm_media_rounded, color: Colors.white, size: 24),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.message, required this.onClose});
  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: AppTypography.sans(color: Colors.white)),
          const SizedBox(height: 12),
          TextButton(onPressed: onClose, child: const Text('Close')),
        ],
      ),
    );
  }
}
