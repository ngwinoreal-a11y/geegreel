import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../feed/data/feed_repository.dart';
import '../application/chat_thread_controller.dart';
import '../data/chat_repository.dart';
import '../data/message_model.dart';

/// 1:1 chat, styled to match the reference: white outgoing bubbles with an
/// inline time + read tick, date separators, an online/typing header, voice
/// notes, emoji reactions, reply, and multi-select delete (for everyone / for
/// me). Poll-based (~4s), optimistic send.
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
  DateTime? _lastTypingPing;

  // UI state for the design's extra affordances.
  final Set<String> _selected = {};
  MessageModel? _replyingTo;
  bool _showEmoji = false;

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      setState(() {});
      _maybePingTyping();
    });
  }

  void _maybePingTyping() {
    if (_controller.text.trim().isEmpty) return;
    final now = DateTime.now();
    if (_lastTypingPing != null && now.difference(_lastTypingPing!).inMilliseconds < 3000) {
      return;
    }
    _lastTypingPing = now;
    ref.read(chatThreadControllerProvider(widget.username).notifier).notifyTyping();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    ref
        .read(chatThreadControllerProvider(widget.username).notifier)
        .send(text, replyToId: _replyingTo?.id);
    _controller.clear();
    setState(() { _replyingTo = null; _showEmoji = false; });
    _scrollToBottom();
  }

  Future<void> _sendImage(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, imageQuality: 85);
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

  Future<void> _startRecording() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    _recordStartedAt = DateTime.now();
    if (!mounted) return;
    setState(() { _recording = true; _recordElapsed = Duration.zero; });
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
    if (mounted) setState(() { _recording = false; _recordStartedAt = null; });
    if (path == null || startedAt == null) return;
    final seconds = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
    if (seconds < 1) return;
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
    setState(() { _recording = false; _recordStartedAt = null; });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  // ----- selection / actions -----

  void _toggleSelect(MessageModel m) {
    setState(() {
      if (_selected.contains(m.id)) {
        _selected.remove(m.id);
      } else {
        _selected.add(m.id);
      }
    });
  }

  void _clearSelection() => setState(() => _selected.clear());

  void _onMessageLongPress(MessageModel m) {
    if (_selecting) {
      _toggleSelect(m);
      return;
    }
    _showMessageMenu(m);
  }

  void _showMessageMenu(MessageModel m) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!m.deleted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final emoji in const ['❤️', '😂', '👍', '😮', '😢', '🙏'])
                      GestureDetector(
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          ref
                              .read(chatThreadControllerProvider(widget.username).notifier)
                              .react(m.id, emoji);
                        },
                        child: Text(emoji, style: const TextStyle(fontSize: 28)),
                      ),
                  ],
                ),
              ),
            if (!m.deleted)
              ListTile(
                leading: const Icon(Icons.reply, color: AppColors.text),
                title: Text('Reply', style: AppTypography.sans()),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  setState(() => _replyingTo = m);
                },
              ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline, color: AppColors.text),
              title: Text('Select', style: AppTypography.sans()),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _toggleSelect(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.danger),
              title: Text('Delete', style: AppTypography.sans(color: AppColors.danger)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmDelete({m.id}, allMine: m.outgoing);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Set<String> ids, {required bool allMine}) async {
    final scope = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            // Delete-for-everyone is only offered when every selected message
            // is the user's own (the server also enforces sender + 15min).
            if (allMine)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: AppColors.danger),
                title: Text('Delete for everyone', style: AppTypography.sans(color: AppColors.danger)),
                onTap: () => Navigator.of(sheetContext).pop('everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.text),
              title: Text('Delete for me', style: AppTypography.sans()),
              onTap: () => Navigator.of(sheetContext).pop('me'),
            ),
            ListTile(
              title: Center(child: Text('Cancel', style: AppTypography.sans(color: AppColors.muted))),
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
    if (scope == null) return;
    final notifier = ref.read(chatThreadControllerProvider(widget.username).notifier);
    for (final id in ids) {
      await notifier.deleteMessage(id, scope: scope);
    }
    _clearSelection();
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
    final thread = threadAsync.valueOrNull;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _selecting ? _buildSelectionBar(thread) : _buildHeader(thread),
      body: threadAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(
          child: Text("Couldn't load this conversation", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (thread) {
          final items = _buildItems(thread.messages);
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    if (item is _DateItem) return _DateSeparator(label: item.label);
                    final m = (item as _MsgItem).message;
                    return _MessageBubble(
                      message: m,
                      selected: _selected.contains(m.id),
                      selecting: _selecting,
                      avatarUrl: thread.withUser.avatarUrl,
                      onTap: () { if (_selecting) _toggleSelect(m); },
                      onLongPress: () => _onMessageLongPress(m),
                    );
                  },
                ),
              ),
              if (thread.blocked || thread.blockedByThem)
                Padding(
                  padding: const EdgeInsets.all(14),
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
                  replyingTo: _replyingTo,
                  showEmoji: _showEmoji,
                  onCancelReply: () => setState(() => _replyingTo = null),
                  onToggleEmoji: () => setState(() => _showEmoji = !_showEmoji),
                  onEmoji: (e) {
                    _controller.text += e;
                    _controller.selection =
                        TextSelection.collapsed(offset: _controller.text.length);
                  },
                  onSend: _send,
                  onAttach: _sendingImage ? null : () => _sendImage(ImageSource.gallery),
                  onCamera: _sendingImage ? null : () => _sendImage(ImageSource.camera),
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

  PreferredSizeWidget _buildHeader(ThreadData? thread) {
    final subtitle = thread == null
        ? null
        : thread.isTyping
            ? 'typing…'
            : thread.online
                ? 'Online'
                : null;
    return AppBar(
      titleSpacing: 0,
      title: Row(
        children: [
          AppAvatar(
            size: 36,
            imageUrl: thread?.withUser.avatarUrl != null ? mediaUrl(thread!.withUser.avatarUrl!) : null,
            displayName: thread?.withUser.displayName ?? widget.username,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(thread?.withUser.displayName ?? '@${widget.username}',
                    style: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(subtitle, style: AppTypography.sans(fontSize: 12, color: AppColors.online)),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (thread != null)
          PopupMenuButton<String>(
            color: AppColors.surface,
            onSelected: (value) async {
              if (value == 'block') {
                await ref.read(feedRepositoryProvider).setBlocked(thread.withUser.id, true);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Blocked @${thread.withUser.username}')));
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'block',
                child: Text('Block', style: AppTypography.sans(color: AppColors.danger)),
              ),
            ],
          ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionBar(ThreadData? thread) {
    final selectedMessages = thread?.messages.where((m) => _selected.contains(m.id)) ?? const [];
    final allMine = selectedMessages.isNotEmpty && selectedMessages.every((m) => m.outgoing);
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
      title: Text('${_selected.length} selected', style: AppTypography.sans(fontSize: 17, fontWeight: FontWeight.w600)),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _confirmDelete({..._selected}, allMine: allMine),
        ),
      ],
    );
  }

  /// Flattens messages into a render list with date separators between days.
  List<_Item> _buildItems(List<MessageModel> messages) {
    final items = <_Item>[];
    DateTime? lastDay;
    for (final m in messages) {
      final day = DateTime(m.createdAt.year, m.createdAt.month, m.createdAt.day);
      if (lastDay == null || day != lastDay) {
        items.add(_DateItem(_dayLabel(day)));
        lastDay = day;
      }
      items.add(_MsgItem(m));
    }
    return items;
  }

  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) {
      const names = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      return names[day.weekday - 1];
    }
    return '${day.day}/${day.month}/${day.year}';
  }
}

// ----- render items -----

sealed class _Item {
  const _Item();
}

class _DateItem extends _Item {
  const _DateItem(this.label);
  final String label;
}

class _MsgItem extends _Item {
  const _MsgItem(this.message);
  final MessageModel message;
}

class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(label, style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
      ),
    );
  }
}

/// Short relative time shown inline in a bubble ("now", "5m", "3h", "2d").
String _shortTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${t.day}/${t.month}';
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.selected,
    required this.selecting,
    required this.avatarUrl,
    required this.onTap,
    required this.onLongPress,
  });

  final MessageModel message;
  final bool selected;
  final bool selecting;
  final String? avatarUrl;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final mine = message.outgoing;
    final bg = selected
        ? (mine ? AppColors.chrome : AppColors.surface)
        : (mine ? AppColors.chrome : AppColors.surface);
    final fg = mine ? AppColors.onChrome : AppColors.text;

    Widget content;
    if (message.deleted) {
      content = _bubble(
        bg: AppColors.surface,
        border: selected,
        child: Text('This message was deleted',
            style: AppTypography.sans(fontSize: 14, color: AppColors.muted)
                .copyWith(fontStyle: FontStyle.italic)),
      );
    } else if (message.audioUrl != null) {
      content = _bubble(
        bg: bg,
        border: selected,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: _VoiceContent(message: message, mine: mine, avatarUrl: avatarUrl),
      );
    } else if (message.imageUrl != null) {
      content = Container(
        decoration: selected
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.lg + 2),
                border: Border.all(color: AppColors.online, width: 2))
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          child: Image.network(mediaUrl(message.imageUrl!), width: 200, fit: BoxFit.cover),
        ),
      );
    } else {
      content = _bubble(
        bg: bg,
        border: selected,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.replyTo != null) _ReplyQuote(reply: message.replyTo!, onDark: !mine),
            _TextWithMeta(message: message, fg: fg),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? AppColors.online.withValues(alpha: 0.10) : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                child: content,
              ),
              if (message.reactions.isNotEmpty)
                Positioned(
                  bottom: -10,
                  right: mine ? 6 : null,
                  left: mine ? null : 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.raised,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.bg, width: 1.5),
                    ),
                    child: Text(
                      message.reactions.map((r) => r.emoji).toSet().join(),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bubble({
    required Color bg,
    required bool border,
    required Widget child,
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: border ? Border.all(color: AppColors.online, width: 2) : null,
      ),
      child: child,
    );
  }
}

/// Message text + inline time + read tick, matching the reference's
/// "Hi 2d ✓✓" treatment. Text wraps; the meta hugs the end of the last line.
class _TextWithMeta extends StatelessWidget {
  const _TextWithMeta({required this.message, required this.fg});
  final MessageModel message;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final metaColor = message.outgoing ? AppColors.onSheetMuted : AppColors.muted;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        _linkedText(message.body ?? '', fg),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_shortTime(message.createdAt),
                  style: AppTypography.sans(fontSize: 11, color: metaColor)),
              if (message.outgoing) ...[
                const SizedBox(width: 3),
                Icon(message.read ? Icons.done_all : Icons.done,
                    size: 14, color: message.read ? AppColors.tickRead : AppColors.tickSent),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

final _urlRegex = RegExp(r'(https?:\/\/[^\s]+)');

/// Renders body text with any URLs as tappable links.
Widget _linkedText(String body, Color color) {
  if (!_urlRegex.hasMatch(body)) {
    return Text(body, style: AppTypography.sans(fontSize: 14, color: color));
  }
  final spans = <InlineSpan>[];
  var index = 0;
  for (final match in _urlRegex.allMatches(body)) {
    if (match.start > index) {
      spans.add(TextSpan(text: body.substring(index, match.start)));
    }
    final url = match.group(0)!;
    spans.add(TextSpan(
      text: url,
      style: const TextStyle(color: AppColors.tickRead, decoration: TextDecoration.underline),
      recognizer: TapGestureRecognizer()
        ..onTap = () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    ));
    index = match.end;
  }
  if (index < body.length) spans.add(TextSpan(text: body.substring(index)));
  return Text.rich(
    TextSpan(style: AppTypography.sans(fontSize: 14, color: color), children: spans),
  );
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.reply, required this.onDark});
  final MessageReplyTo reply;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final ink = onDark ? AppColors.text : AppColors.onChrome;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: BoxDecoration(
        color: (onDark ? AppColors.raised : AppColors.sheetFill),
        borderRadius: BorderRadius.circular(8),
        border: const Border(left: BorderSide(color: AppColors.accent, width: 3)),
      ),
      child: Text(
        reply.snippet,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.sans(fontSize: 12, color: ink.withValues(alpha: 0.75)),
      ),
    );
  }
}

class _VoiceContent extends StatefulWidget {
  const _VoiceContent({required this.message, required this.mine, required this.avatarUrl});
  final MessageModel message;
  final bool mine;
  final String? avatarUrl;

  @override
  State<_VoiceContent> createState() => _VoiceContentState();
}

class _VoiceContentState extends State<_VoiceContent> {
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
    _player.playing ? await _player.pause() : await _player.play();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.mine ? AppColors.onChrome : AppColors.text;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppAvatar(
          size: 34,
          imageUrl: widget.avatarUrl != null ? mediaUrl(widget.avatarUrl!) : null,
          displayName: '♪',
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: _toggle,
          child: StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snapshot) {
              final playing = snapshot.data?.playing ?? false;
              return Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  color: fg, size: 34);
            },
          ),
        ),
        const SizedBox(width: 8),
        _Waveform(color: fg.withValues(alpha: 0.5)),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_durationLabel(), style: AppTypography.sans(fontSize: 12, color: fg)),
            const SizedBox(height: 2),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_shortTime(widget.message.createdAt),
                  style: AppTypography.sans(fontSize: 10, color: AppColors.onSheetMuted)),
              if (widget.mine) ...[
                const SizedBox(width: 3),
                Icon(widget.message.read ? Icons.done_all : Icons.done,
                    size: 12, color: widget.message.read ? AppColors.tickRead : AppColors.tickSent),
              ],
            ]),
          ],
        ),
      ],
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
      width: 68,
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
              child: Text('This person messaged you. Accept to reply.',
                  style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
            ),
            const SizedBox(width: 10),
            TextButton(onPressed: onDecline, child: const Text('Delete')),
            ElevatedButton(onPressed: onAccept, child: const Text('Confirm')),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.replyingTo,
    required this.showEmoji,
    required this.onCancelReply,
    required this.onToggleEmoji,
    required this.onEmoji,
    required this.onSend,
    this.onAttach,
    this.onCamera,
    required this.recording,
    required this.recordElapsed,
    required this.onRecordStart,
    required this.onRecordEnd,
    required this.onRecordCancel,
  });

  final TextEditingController controller;
  final MessageModel? replyingTo;
  final bool showEmoji;
  final VoidCallback onCancelReply;
  final VoidCallback onToggleEmoji;
  final ValueChanged<String> onEmoji;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final VoidCallback? onCamera;
  final bool recording;
  final Duration recordElapsed;
  final VoidCallback onRecordStart;
  final VoidCallback onRecordEnd;
  final VoidCallback onRecordCancel;

  static const _emojis = [
    '😀','😂','🥰','😍','😊','😉','😎','😭','😢','😡','👍','🙏','🔥','❤️','💯','🎉',
    '😅','😳','🤔','🙌','👏','💪','✨','⭐','😴','🤝','😘','😜','🥳','😱','🤗','👌',
  ];

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replyingTo != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: const Border(left: BorderSide(color: AppColors.accent, width: 3)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(replyingTo!.outgoing ? 'Replying to yourself' : 'Replying',
                            style: AppTypography.sans(fontSize: 11, color: AppColors.accent)),
                        Text(replyingTo!.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close, size: 18, color: AppColors.muted), onPressed: onCancelReply),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!recording)
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(showEmoji ? Icons.keyboard : Icons.emoji_emotions_outlined,
                                color: AppColors.muted),
                            onPressed: onToggleEmoji,
                          ),
                          Expanded(
                            child: TextField(
                              controller: controller,
                              style: AppTypography.sans(fontSize: 14),
                              minLines: 1,
                              maxLines: 5,
                              decoration: const InputDecoration(
                                hintText: 'Message',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                              onSubmitted: (_) => onSend(),
                            ),
                          ),
                          if (!hasText) ...[
                            IconButton(
                              icon: onAttach == null
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.attach_file, color: AppColors.muted),
                              onPressed: onAttach,
                            ),
                            IconButton(
                              icon: const Icon(Icons.photo_camera_outlined, color: AppColors.muted),
                              onPressed: onCamera,
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.delete_outline, color: AppColors.muted),
                            onPressed: onRecordCancel,
                          ),
                          Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Text(_fmt(recordElapsed), style: AppTypography.sans(fontSize: 13)),
                          const Spacer(),
                          Text('Release to send', style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                if (hasText && !recording)
                  GestureDetector(
                    onTap: onSend,
                    child: Container(
                      width: 48, height: 48,
                      decoration: const BoxDecoration(color: AppColors.online, shape: BoxShape.circle),
                      child: const Icon(Icons.send_rounded, color: Colors.white, size: 22),
                    ),
                  )
                else
                  GestureDetector(
                    onLongPressStart: (_) => onRecordStart(),
                    onLongPressEnd: (_) => onRecordEnd(),
                    child: Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        color: recording ? AppColors.danger : AppColors.online,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.mic, color: Colors.white, size: 22),
                    ),
                  ),
              ],
            ),
          ),
          if (showEmoji)
            SizedBox(
              height: 200,
              child: GridView.count(
                crossAxisCount: 8,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final e in _emojis)
                    GestureDetector(
                      onTap: () => onEmoji(e),
                      child: Center(child: Text(e, style: const TextStyle(fontSize: 24))),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
