import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../application/chat_thread_controller.dart';
import '../data/message_model.dart';

/// Ports index.html's chatPage() text/image/voice-note path: poll-based
/// thread (~4s), optimistic send. Reply-to and multi-select delete are
/// still deferred — this covers real 1:1 text, image, and voice messaging
/// against the live backend end to end.
class ThreadScreen extends ConsumerStatefulWidget {
  const ThreadScreen({super.key, required this.username});
  final String username;

  @override
  ConsumerState<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends ConsumerState<ThreadScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();
  bool _sendingImage = false;
  bool _recording = false;
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTimer;
  DateTime? _recordStartedAt;

  @override
  void initState() {
    super.initState();
    // Drives the send-icon <-> mic-icon swap in _Composer as the user types.
    _controller.addListener(() => setState(() {}));
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    ref.read(chatThreadControllerProvider(widget.username).notifier).send(text);
    _controller.clear();
    _scrollToBottom();
  }

  Future<void> _sendImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    setState(() => _sendingImage = true);
    try {
      await ref
          .read(chatThreadControllerProvider(widget.username).notifier)
          .sendImage(File(picked.path));
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sendingImage = false);
    }
  }

  /// Hold-to-record like WhatsApp: onLongPressStart begins capture,
  /// onLongPressEnd stops and sends. `POST /api/messages/media` with
  /// kind=audio already exists server-side (src/index.js ~2631) — this was
  /// just never wired up to a real mic on the client before.
  Future<void> _startRecording() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    _recordStartedAt = DateTime.now();
    if (!mounted) return;
    setState(() {
      _recording = true;
      _recordElapsed = Duration.zero;
    });
    _recordTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final startedAt = _recordStartedAt;
      if (!mounted || startedAt == null) return;
      setState(() => _recordElapsed = DateTime.now().difference(startedAt));
    });
  }

  Future<void> _stopRecordingAndSend() async {
    if (!_recording) return;
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    final startedAt = _recordStartedAt;
    if (mounted) {
      setState(() {
        _recording = false;
        _recordStartedAt = null;
      });
    }
    if (path == null || startedAt == null) return;
    final seconds = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
    if (seconds < 1) return; // Accidental tap, not a real note.
    await ref
        .read(chatThreadControllerProvider(widget.username).notifier)
        .sendVoice(File(path), seconds);
    _scrollToBottom();
  }

  Future<void> _cancelRecording() async {
    if (!_recording) return;
    _recordTimer?.cancel();
    await _recorder.stop();
    if (!mounted) return;
    setState(() {
      _recording = false;
      _recordStartedAt = null;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _recorder.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final threadAsync = ref.watch(chatThreadControllerProvider(widget.username));

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(threadAsync.valueOrNull?.withUser.displayName ?? '@${widget.username}')),
      body: threadAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(
          child: Text("Couldn't load this conversation", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (thread) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  itemCount: thread.messages.length,
                  itemBuilder: (context, i) {
                    final msg = thread.messages[i];
                    return _Bubble(message: msg, mine: msg.outgoing);
                  },
                ),
              ),
              if (thread.blocked || thread.blockedByThem)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    thread.blockedByThem ? 'You cannot reply to this conversation' : 'You blocked this user',
                    style: AppTypography.sans(color: AppColors.muted, fontSize: 13),
                  ),
                )
              else if (thread.isPendingRequestToMe)
                _RequestBanner(
                  onAccept: () => ref
                      .read(chatThreadControllerProvider(widget.username).notifier)
                      .respond(accept: true),
                  onDecline: () => ref
                      .read(chatThreadControllerProvider(widget.username).notifier)
                      .respond(accept: false),
                )
              else
                _Composer(
                  controller: _controller,
                  onSend: _send,
                  onAttach: _sendingImage ? null : _sendImage,
                  recording: _recording,
                  recordElapsed: _recordElapsed,
                  onRecordStart: _startRecording,
                  onRecordEnd: _stopRecordingAndSend,
                  onRecordCancel: _cancelRecording,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final MessageModel message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    if (message.audioUrl != null) {
      return _VoiceBubble(message: message, mine: mine);
    }
    if (message.imageUrl != null) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            child: Image.network(
              mediaUrl(message.imageUrl!),
              width: 200,
              fit: BoxFit.cover,
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: mine ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: Text(
          message.body ?? '',
          style: AppTypography.sans(
            fontSize: 14,
            color: mine ? AppColors.onAccent : AppColors.text,
          ),
        ),
      ),
    );
  }
}

/// Voice-note bubble: play/pause + a static bar "waveform" (real waveform
/// decoding is deferred — see the plan's just_waveform note) + duration
/// label sourced from the server's `audioDuration` (falls back to 0:00 if
/// somehow missing rather than blocking playback on it).
class _VoiceBubble extends StatefulWidget {
  const _VoiceBubble({required this.message, required this.mine});
  final MessageModel message;
  final bool mine;

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  final _player = AudioPlayer();
  bool _loaded = false;
  bool _loadFailed = false;

  Future<void> _toggle() async {
    if (_loadFailed) return;
    if (!_loaded) {
      try {
        await _player.setUrl(mediaUrl(widget.message.audioUrl!));
        _loaded = true;
      } catch (_) {
        if (mounted) setState(() => _loadFailed = true);
        return;
      }
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mine = widget.mine;
    final fg = mine ? AppColors.onAccent : AppColors.text;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: mine ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _toggle,
              child: StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return Icon(
                    playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                    color: fg,
                    size: 30,
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            _Waveform(color: fg.withValues(alpha: 0.55)),
            const SizedBox(width: 8),
            Text(_durationLabel(), style: AppTypography.sans(fontSize: 12, color: fg)),
          ],
        ),
      ),
    );
  }

  String _durationLabel() {
    final seconds = widget.message.audioDuration?.round() ?? 0;
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform({required this.color});
  final Color color;

  static const _heights = [6.0, 12.0, 18.0, 10.0, 16.0, 8.0, 14.0, 6.0, 11.0, 9.0];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 70,
      height: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final h in _heights)
            Container(
              width: 2.5,
              height: h,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
            ),
        ],
      ),
    );
  }
}

/// Ports design-2.css section G's Confirm/Delete pair for a pending
/// message request — shown instead of the composer until acted on.
class _RequestBanner extends StatelessWidget {
  const _RequestBanner({required this.onAccept, required this.onDecline});
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'This person messaged you. Accept to reply.',
                style: AppTypography.sans(fontSize: 13, color: AppColors.muted),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: onDecline,
              child: const Text('Delete'),
            ),
            ElevatedButton(
              onPressed: onAccept,
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    this.onAttach,
    required this.recording,
    required this.recordElapsed,
    required this.onRecordStart,
    required this.onRecordEnd,
    required this.onRecordCancel,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final bool recording;
  final Duration recordElapsed;
  final VoidCallback onRecordStart;
  final VoidCallback onRecordEnd;
  final VoidCallback onRecordCancel;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 10),
        child: Row(
          children: [
            if (!recording) ...[
              IconButton(
                icon: onAttach == null
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.image_outlined, color: AppColors.muted),
                onPressed: onAttach,
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  style: AppTypography.sans(fontSize: 14),
                  decoration: const InputDecoration(hintText: 'Message'),
                  onSubmitted: (_) => onSend(),
                ),
              ),
            ] else ...[
              IconButton(
                icon: const Icon(Icons.delete_outline, color: AppColors.muted),
                onPressed: onRecordCancel,
              ),
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(_formatDuration(recordElapsed), style: AppTypography.sans(fontSize: 13, color: AppColors.text)),
                    const SizedBox(width: 8),
                    Text('Release to send', style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                  ],
                ),
              ),
            ],
            const SizedBox(width: 4),
            if (hasText && !recording)
              IconButton(
                icon: const Icon(Icons.send_rounded, color: AppColors.accent),
                onPressed: onSend,
              )
            else
              GestureDetector(
                onLongPressStart: (_) => onRecordStart(),
                onLongPressEnd: (_) => onRecordEnd(),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: recording ? AppColors.danger : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.mic, color: recording ? Colors.white : AppColors.accent),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
