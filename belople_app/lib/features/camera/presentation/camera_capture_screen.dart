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
  bool _showFilters = false;

  _CamMode _mode = _CamMode.short;
  int _maxSeconds = 60;
  final _picker = ImagePicker();

  // Max-record options shown as pills in Short mode.
  static const _durations = [15, 60, 180];
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

                      // Right rail: flash, filters toggle.
                      Positioned(
                        top: 64, right: 8,
                        child: Column(children: [
                          _RoundIcon(icon: _flashIcon, onTap: _cycleFlash),
                          const SizedBox(height: 16),
                          _RoundIcon(
                            icon: Icons.auto_awesome,
                            active: _showFilters,
                            onTap: () => setState(() => _showFilters = !_showFilters),
                          ),
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

                      // Filter strip.
                      if (_showFilters)
                        Positioned(
                          left: 0, right: 0, bottom: 190,
                          child: SizedBox(
                            height: 60,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: kCameraFilters.length,
                              separatorBuilder: (_, _) => const SizedBox(width: 10),
                              itemBuilder: (context, i) => _FilterChip(
                                label: kCameraFilters[i].label,
                                selected: i == _filterIndex,
                                onTap: () => setState(() => _filterIndex = i),
                              ),
                            ),
                          ),
                        ),

                      // Bottom controls: duration pills, record, mode tabs, gallery.
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
                                              fontSize: _maxSeconds == s ? 15 : 13,
                                              fontWeight: _maxSeconds == s ? FontWeight.w700 : FontWeight.w500,
                                              color: _maxSeconds == s ? Colors.white : Colors.white60,
                                            )),
                                      ),
                                    ),
                                ],
                              ),
                            const SizedBox(height: 16),
                            // Record row: gallery, big button, spacer.
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _pickFromGallery,
                                  child: Container(
                                    width: 44, height: 44,
                                    decoration: BoxDecoration(
                                      color: Colors.white24,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white54),
                                    ),
                                    child: const Icon(Icons.photo_library_outlined, color: Colors.white, size: 22),
                                  ),
                                ),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _onCapture,
                                  child: Container(
                                    width: 78, height: 78,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 4),
                                    ),
                                    child: Center(
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 200),
                                        width: _recording ? 30 : 62,
                                        height: _recording ? 30 : 62,
                                        decoration: BoxDecoration(
                                          color: _mode == _CamMode.public ? Colors.white : AppColors.danger,
                                          borderRadius: BorderRadius.circular(_recording ? 8 : 40),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 44),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _modeTabs(),
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
                  fontSize: 14,
                  fontWeight: _mode == m ? FontWeight.w800 : FontWeight.w500,
                  color: _mode == m ? AppColors.accent : Colors.white70,
                )),
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

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.black45,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white54),
        ),
        child: Text(label,
            style: TextStyle(color: selected ? Colors.black : Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap, this.active = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: active ? AppColors.accent : Colors.black45, shape: BoxShape.circle),
        child: Icon(icon, color: active ? AppColors.onAccent : Colors.white, size: 24),
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
