import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
// Prefixed on purpose: this package is a fork of the camera plugin and exports
// its own CameraController and CameraPreview under the same names as the real
// one, which the rest of the app uses. Without the prefix whichever import
// came last would silently win.
import 'package:rtmp_broadcaster/camera.dart' as rtmp;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/top_toast.dart';
import '../data/live_repository.dart';
import 'live_overlay.dart';

/// The creator's side: their camera, pushed to the ingest URL the backend
/// handed back, with the room's comments and headcount over it.
///
/// The provider is not named anywhere in here. It receives somewhere to push
/// to and pushes there.
class LiveBroadcastScreen extends ConsumerStatefulWidget {
  const LiveBroadcastScreen({super.key, required this.start});

  final LiveStart start;

  @override
  ConsumerState<LiveBroadcastScreen> createState() => _LiveBroadcastScreenState();
}

class _LiveBroadcastScreenState extends ConsumerState<LiveBroadcastScreen> {
  rtmp.CameraController? _camera;
  bool _streaming = false;
  String? _error;
  bool _ending = false;

  Timer? _poll;
  Timer? _clock;
  int _elapsed = 0;
  int _since = 0;
  int _viewers = 0;
  final List<LiveComment> _comments = [];
  bool _warned = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    try {
      final cameras = await rtmp.availableCameras();
      if (cameras.isEmpty) throw StateError('no camera on this device');
      // Front camera first — going live is almost always to talk to people.
      final front = cameras.firstWhere(
        (c) => c.lensDirection == rtmp.CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      // 720p, deliberately, and it is a money decision as much as a picture
      // one: the provider bills the encode by the resolution it receives, every
      // viewer pays for it in mobile data, and on the phones this app is for
      // 1080p mostly buys a hotter handset. `high` is 720p in this plugin's
      // scale (low 240 · medium 480 · high 720 · veryHigh 1080).
      final controller = rtmp.CameraController(
        front,
        rtmp.ResolutionPreset.high,
        streamingPreset: rtmp.ResolutionPreset.high,
        enableAudio: true,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() => _camera = controller);

      // ~1.5 Mbps: enough for 720p talking-head video, low enough to hold on a
      // mobile uplink here. The encoder drops quality rather than frames when
      // the connection tightens, which is the trade the plan asks for.
      await controller.startVideoStreaming(widget.start.publishUrl, bitrate: 1500 * 1024);
      if (!mounted) return;
      setState(() => _streaming = true);
      _startTimers();
    } catch (e) {
      // Nothing about going live is allowed to fail quietly: the creator is
      // standing there believing they are on air.
      debugPrint('[BLLIVE] could not start broadcasting: $e');
      if (mounted) setState(() => _error = "Couldn't start your live — check your connection and try again");
    }
  }

  void _startTimers() {
    // The room, every 3 seconds. One request brings back new comments, the
    // headcount and whether it is still on.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed++);

      // The limit is real and it is ours: at it, this ends itself. The backend
      // and the provider each hold the same limit underneath for the case
      // where this app is not running to enforce it.
      final left = widget.start.maxSeconds - _elapsed;
      if (left == 60 && !_warned) {
        _warned = true;
        showTopToast(context, 'One minute left on this live');
      }
      if (left <= 0) _end(reason: 'time');
    });
  }

  Future<void> _tick() async {
    try {
      final t = await ref.read(liveRepositoryProvider).tick(widget.start.sessionId, since: _since);
      if (!mounted) return;
      setState(() {
        _viewers = t.viewerCount;
        _since = t.since;
        _comments.addAll(t.comments);
        // Only what fits on screen is kept. Nobody scrolls a live chat back,
        // and holding an hour of it is how the screen gets slow near the end.
        if (_comments.length > 60) _comments.removeRange(0, _comments.length - 60);
      });
      if (t.ended) _end(silent: true);
    } catch (e) {
      // A dropped poll is survivable — the video is a separate connection and
      // is probably still up — so it stays quiet on screen but not in the log.
      debugPrint('[BLLIVE] poll failed: $e');
    }
  }

  Future<void> _end({bool silent = false, String reason = 'creator'}) async {
    if (_ending) return;
    _ending = true;
    _poll?.cancel();
    _clock?.cancel();

    try { await _camera?.stopVideoStreaming(); }
    catch (e) { debugPrint('[BLLIVE] stopVideoStreaming failed: $e'); }

    try { await ref.read(liveRepositoryProvider).end(widget.start.sessionId); }
    catch (e) {
      // The backend's sweeper closes it either way, so the creator is not left
      // stuck on a screen because a request failed — but this is the path that
      // leaves a stream running longest, so it is logged loudly.
      debugPrint('[BLLIVE] ending the session failed: $e');
    }

    if (!mounted) return;
    if (!silent) {
      showTopToast(context, reason == 'time' ? 'Your live reached its time limit' : 'Live ended');
    }
    context.pop();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _clock?.cancel();
    // Best effort — the session is closed by _end, and by the backend's sweeper
    // if this screen went away without one.
    _camera?.dispose();
    super.dispose();
  }

  String get _clockLabel {
    final m = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cam = _camera;
    return PopScope(
      // Backing out of a live is ending it, so it asks first rather than
      // leaving a paid stream running behind a closed screen.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text('End your live?',
                style: AppTypography.sans(fontSize: 17, fontWeight: FontWeight.w700)),
            content: Text('Everyone watching will be sent back.',
                style: AppTypography.sans(fontSize: 14)),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Stay live')),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                child: const Text('End live'),
              ),
            ],
          ),
        );
        if (leave == true) await _end();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _error != null
            ? _LiveFailed(message: _error!, onClose: () => context.pop())
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (cam != null && cam.value.isInitialized == true)
                    rtmp.CameraPreview(cam)
                  else
                    const Center(child: CircularProgressIndicator(color: Colors.white)),

                  LiveOverlay(
                    title: null,
                    viewers: _viewers,
                    comments: _comments,
                    isBroadcaster: true,
                    connecting: !_streaming,
                    clockLabel: _clockLabel,
                    onClose: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
      ),
    );
  }
}

class _LiveFailed extends StatelessWidget {
  const _LiveFailed({required this.message, required this.onClose});
  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 44),
              const SizedBox(height: 14),
              Text(message,
                  textAlign: TextAlign.center,
                  style: AppTypography.sans(fontSize: 15, color: Colors.white)),
              const SizedBox(height: 18),
              TextButton(onPressed: onClose, child: const Text('Close')),
            ],
          ),
        ),
      );
}
