import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import 'camera_filters.dart';

/// In-app camera: live preview with a colour-filter strip, tap-to-record (max
/// 60s), flip camera, and flash toggle. Pops back the recorded file's path as
/// a String so the composer can preview and upload it — the OS-picker path in
/// the composer remains as the fallback when a device has no usable camera.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
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

  static const _maxRecord = Duration(seconds: 60);

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
    final previous = _controller;
    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: true,
    );
    _controller = controller;
    _cameraIndex = index;
    try {
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
    } catch (_) {
      if (mounted) setState(() { _initializing = false; _error = "Couldn't start the camera"; });
      return;
    }
    await previous?.dispose();
    if (mounted) setState(() => _initializing = false);
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

  Future<void> _toggleRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_recording) {
      _timer?.cancel();
      try {
        final file = await controller.stopVideoRecording();
        if (mounted) {
          setState(() => _recording = false);
          context.pop(file.path);
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
        if (_elapsed >= _maxRecord) _toggleRecording();
      });
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
    try {
      await controller.setFlashMode(next);
    } catch (_) {}
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _error != null
            ? _CameraError(message: _error!, onClose: () => context.pop())
            : _initializing || controller == null || !controller.value.isInitialized
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      // Live preview with the selected colour filter.
                      Center(
                        child: filter.colorFilter == null
                            ? CameraPreview(controller)
                            : ColorFiltered(
                                colorFilter: filter.colorFilter!,
                                child: CameraPreview(controller),
                              ),
                      ),

                      // Top controls: close, flash.
                      Positioned(
                        top: 8,
                        left: 8,
                        right: 8,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _RoundIcon(icon: Icons.close, onTap: () => context.pop()),
                            if (_recording)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 8, height: 8,
                                      decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(_fmt(_elapsed), style: AppTypography.sans(fontSize: 13, color: Colors.white)),
                                  ],
                                ),
                              ),
                            _RoundIcon(icon: _flashIcon, onTap: _cycleFlash),
                          ],
                        ),
                      ),

                      // Filter strip.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 150,
                        child: SizedBox(
                          height: 64,
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

                      // Bottom bar: record + flip.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 40,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            GestureDetector(
                              onTap: _toggleRecording,
                              child: Container(
                                width: 76,
                                height: 76,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 4),
                                ),
                                child: Center(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    width: _recording ? 30 : 60,
                                    height: _recording ? 30 : 60,
                                    decoration: BoxDecoration(
                                      color: AppColors.danger,
                                      borderRadius: BorderRadius.circular(_recording ? 8 : 30),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (_cameras.length > 1)
                              Padding(
                                padding: const EdgeInsets.only(left: 36),
                                child: _RoundIcon(icon: Icons.flip_camera_ios, onTap: _flip),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
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
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.black45,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white54),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
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
