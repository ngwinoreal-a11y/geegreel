import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
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
import '../../../core/widgets/linkified_text.dart';
import '../../feed/data/feed_repository.dart';
import '../../public_feed/data/link_preview_repository.dart';
import '../../feed/presentation/single_video_screen.dart';
import '../application/chat_thread_controller.dart';
import '../application/voice_player.dart';
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

  // Scroll: stay pinned to the newest message unless the user scrolls up.
  bool _stick = true;
  bool _firstLoad = true;
  int _lastCount = -1;

  // Per-message keys so a reply quote can scroll to the message it answers,
  // with a brief highlight on arrival.
  final Map<String, GlobalKey> _msgKeys = {};
  String? _highlightId;

  void _jumpToMessage(String id) {
    final ctx = _msgKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.35);
    }
    setState(() => _highlightId = id);
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (mounted && _highlightId == id) setState(() => _highlightId = null);
    });
  }

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      setState(() {});
      _maybePingTyping();
    });
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // Within ~80px of the bottom counts as "at the bottom" (keep auto-scroll).
    _stick = pos.pixels >= pos.maxScrollExtent - 80;
  }

  void _jumpBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
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
    if (!await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Microphone permission is needed to record a voice note')));
      }
      return;
    }
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
    if (seconds < 0.5) return; // guard against an accidental double-tap
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
              onTap: () async {
                Navigator.of(sheetContext).pop();
                // Let this sheet finish dismissing before opening the next —
                // showing a second modal in the same frame silently no-ops.
                await Future<void>.delayed(const Duration(milliseconds: 220));
                if (mounted) _confirmDelete({m.id}, allMine: m.outgoing);
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
          // Open at (and stay pinned to) the newest message, like every chat
          // app. On first load the content height keeps growing as images and
          // voice bubbles lay out, so re-jump a few times to settle at the
          // true bottom; afterwards only re-jump when a new message arrives
          // and the user hasn't scrolled up to read history.
          if (thread.messages.isNotEmpty) {
            if (_firstLoad) {
              _firstLoad = false;
              _lastCount = thread.messages.length;
              for (final ms in const [0, 120, 350, 700]) {
                Future.delayed(Duration(milliseconds: ms), () {
                  if (mounted && _stick) _jumpBottom();
                });
              }
            } else if (thread.messages.length != _lastCount) {
              _lastCount = thread.messages.length;
              if (_stick) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpBottom());
            }
          }
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
                    return KeyedSubtree(
                      key: _msgKeys.putIfAbsent(m.id, () => GlobalKey()),
                      child: _MessageBubble(
                        message: m,
                        selected: _selected.contains(m.id),
                        selecting: _selecting,
                        highlighted: _highlightId == m.id,
                        avatarUrl: thread.withUser.avatarUrl,
                        onTap: () { if (_selecting) _toggleSelect(m); },
                        onLongPress: () => _onMessageLongPress(m),
                        onReplyTap: m.replyTo != null ? () => _jumpToMessage(m.replyTo!.id) : null,
                      ),
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
              final block = value == 'block';
              await ref.read(feedRepositoryProvider).setBlocked(thread.withUser.id, block);
              ref.invalidate(chatThreadControllerProvider(widget.username));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(block
                      ? 'Blocked @${thread.withUser.username}'
                      : 'Unblocked @${thread.withUser.username}')));
            },
            itemBuilder: (context) => [
              thread.blocked
                  ? PopupMenuItem(
                      value: 'unblock',
                      child: Text('Unblock', style: AppTypography.sans()),
                    )
                  : PopupMenuItem(
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
    this.highlighted = false,
    this.onReplyTap,
  });

  final MessageModel message;
  final bool selected;
  final bool selecting;
  final String? avatarUrl;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool highlighted;
  final VoidCallback? onReplyTap;

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
      content = GestureDetector(
        onTap: () {
          if (selecting) {
            onTap();
          } else {
            _openImageFullscreen(context, mediaUrl(message.imageUrl!));
          }
        },
        child: Container(
          decoration: selected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.lg + 2),
                  border: Border.all(color: AppColors.online, width: 2))
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            child: CachedNetworkImage(imageUrl: mediaUrl(message.imageUrl!), width: 200, fit: BoxFit.cover),
          ),
        ),
      );
    } else if (message.videoId != null) {
      content = _SharedVideoContent(
        videoId: message.videoId!,
        selected: selected,
        selecting: selecting,
        onSelect: onTap,
      );
    } else {
      content = _bubble(
        bg: bg,
        border: selected,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.replyTo != null) _ReplyQuote(reply: message.replyTo!, onDark: !mine, onTap: onReplyTap),
            _TextWithMeta(message: message, fg: fg),
            if (firstUrl(message.body ?? '') != null)
              _ChatLinkPreview(url: firstUrl(message.body!)!, onDark: !mine),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        color: highlighted
            ? AppColors.accent.withValues(alpha: 0.22)
            : selected
                ? AppColors.online.withValues(alpha: 0.10)
                : Colors.transparent,
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
              // Words, not ticks. One tick versus two is a convention people
              // have to already know; "Sent"/"Seen" says the same thing to
              // anyone reading it.
              if (message.outgoing) ...[
                const SizedBox(width: 5),
                Text(message.read ? 'Seen' : 'Sent',
                    style: AppTypography.sans(
                      fontSize: 11,
                      fontWeight: message.read ? FontWeight.w600 : FontWeight.w400,
                      color: message.read ? AppColors.tickRead : metaColor,
                    )),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Opens a full-screen, pinch-zoomable view of a chat image. Tap or the
/// system back gesture closes it (one back = return to the thread).
void _openImageFullscreen(BuildContext context, String url) {
  Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    barrierColor: Colors.black,
    pageBuilder: (context, _, _) => GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain)),
            ),
          ),
          Positioned(
            top: 40,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    ),
  ));
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

/// A compact link preview shown under a chat message that contains a URL —
/// the link's thumbnail + title, tappable to open it.
class _ChatLinkPreview extends ConsumerWidget {
  const _ChatLinkPreview({required this.url, required this.onDark});
  final String url;
  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(linkPreviewProvider(url)).valueOrNull;
    if (preview == null || preview.title.isEmpty) return const SizedBox.shrink();
    final ink = onDark ? AppColors.text : AppColors.onChrome;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        child: Container(
          width: 220,
          decoration: BoxDecoration(
            color: (onDark ? AppColors.raised : AppColors.sheetFill),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (preview.image != null && preview.image!.isNotEmpty)
                AspectRatio(
                  aspectRatio: 1.9,
                  child: CachedNetworkImage(imageUrl: preview.image!, fit: BoxFit.cover,
                      errorWidget: (_, _, _) => const SizedBox.shrink()),
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(preview.siteName ?? Uri.parse(url).host,
                        style: AppTypography.sans(fontSize: 10, color: ink.withValues(alpha: 0.6))),
                    const SizedBox(height: 2),
                    Text(preview.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.sans(fontSize: 12, fontWeight: FontWeight.w600, color: ink)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A video shared into the chat (a message carrying a videoId): shows the
/// video's thumbnail with a play badge; tapping opens the full player.
class _SharedVideoContent extends ConsumerWidget {
  const _SharedVideoContent({
    required this.videoId,
    required this.selected,
    required this.selecting,
    required this.onSelect,
  });
  final String videoId;
  final bool selected;
  final bool selecting;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final video = ref.watch(singleVideoProvider(videoId)).valueOrNull;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => selecting ? onSelect() : context.push('/v/$videoId'),
      child: Container(
        width: 150,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: selected ? Border.all(color: AppColors.online, width: 2) : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: AspectRatio(
          aspectRatio: 9 / 14,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: const BoxDecoration(color: AppColors.raised),
                child: video?.thumbUrl != null
                    ? CachedNetworkImage(imageUrl: mediaUrl(video!.thumbUrl!), fit: BoxFit.cover)
                    : null,
              ),
              const Center(
                child: Icon(Icons.play_circle_fill, color: Colors.white, size: 44,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 10)]),
              ),
              Positioned(
                left: 6, bottom: 6, right: 6,
                child: Text(video?.caption ?? 'Video',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.sans(fontSize: 11, color: Colors.white)
                        .copyWith(shadows: const [Shadow(color: Colors.black87, blurRadius: 6)])),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.reply, required this.onDark, this.onTap});
  final MessageReplyTo reply;
  final bool onDark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ink = onDark ? AppColors.text : AppColors.onChrome;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
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
      ),
    );
  }
}

/// Voice-note bubble backed by the shared [voicePlayerProvider] — only one
/// note plays at a time, so tapping a second one stops the first. Shows a
/// play/pause control, a progress waveform you can tap or drag to seek, and
/// the elapsed / total time.
class _VoiceContent extends ConsumerWidget {
  const _VoiceContent({required this.message, required this.mine, required this.avatarUrl});
  final MessageModel message;
  final bool mine;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fg = mine ? AppColors.onChrome : AppColors.text;
    final isActive = ref.watch(voicePlayerProvider) == message.id;
    final vp = ref.read(voicePlayerProvider.notifier);
    final totalSeconds = message.audioDuration?.round() ?? 0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppAvatar(size: 34, imageUrl: avatarUrl != null ? mediaUrl(avatarUrl!) : null, displayName: '♪'),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () => vp.toggle(message.id, mediaUrl(message.audioUrl!)),
          child: isActive
              ? StreamBuilder<PlayerState>(
                  stream: vp.player.playerStateStream,
                  builder: (context, snap) {
                    final playing = snap.data?.playing ?? false;
                    return Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill, color: fg, size: 34);
                  },
                )
              : Icon(Icons.play_circle_fill, color: fg, size: 34),
        ),
        const SizedBox(width: 8),
        if (isActive)
          StreamBuilder<Duration>(
            stream: vp.player.positionStream,
            builder: (context, snap) {
              final pos = snap.data ?? Duration.zero;
              final total = vp.player.duration ?? Duration(seconds: totalSeconds);
              final frac = total.inMilliseconds > 0 ? pos.inMilliseconds / total.inMilliseconds : 0.0;
              return Row(mainAxisSize: MainAxisSize.min, children: [
                _ProgressWaveform(color: fg, progress: frac.clamp(0.0, 1.0).toDouble(), onSeek: (f) => vp.seek(total * f)),
                const SizedBox(width: 8),
                _meta(fg, _fmtDur(pos.inSeconds)),
              ]);
            },
          )
        else
          Row(mainAxisSize: MainAxisSize.min, children: [
            _ProgressWaveform(color: fg, progress: 0),
            const SizedBox(width: 8),
            _meta(fg, _fmtDur(totalSeconds)),
          ]),
      ],
    );
  }

  Widget _meta(Color fg, String duration) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(duration, style: AppTypography.sans(fontSize: 12, color: fg)),
        const SizedBox(height: 2),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text(_shortTime(message.createdAt), style: AppTypography.sans(fontSize: 10, color: AppColors.onSheetMuted)),
          if (mine) ...[
            const SizedBox(width: 5),
            Text(message.read ? 'Seen' : 'Sent',
                style: AppTypography.sans(
                  fontSize: 10,
                  fontWeight: message.read ? FontWeight.w600 : FontWeight.w400,
                  color: message.read ? AppColors.tickRead : AppColors.onSheetMuted,
                )),
          ],
        ]),
      ],
    );
  }

  static String _fmtDur(int seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// A bar "waveform" whose bars fill up to [progress] (0-1); tapping or
/// dragging along it seeks via [onSeek].
class _ProgressWaveform extends StatelessWidget {
  const _ProgressWaveform({required this.color, required this.progress, this.onSeek});
  final Color color;
  final double progress;
  final ValueChanged<double>? onSeek;

  static const _heights = [6.0, 12.0, 18.0, 10.0, 16.0, 8.0, 14.0, 6.0, 11.0, 9.0, 15.0, 7.0];
  static const _width = 96.0;

  void _seekAt(Offset local) => onSeek?.call((local.dx / _width).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _seekAt(d.localPosition),
      onHorizontalDragUpdate: (d) => _seekAt(d.localPosition),
      child: SizedBox(
        width: _width,
        height: 22,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < _heights.length; i++)
              Container(
                width: 3,
                height: _heights[i],
                decoration: BoxDecoration(
                  color: (i / _heights.length) <= progress ? color : color.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
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
                          Text('Recording… tap ➤ to send', style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                // Tap-to-record (matches the web app's chat mic): tap the mic
                // to start, tap the green send to stop and send. No holding.
                if (recording)
                  GestureDetector(
                    onTap: onRecordEnd,
                    child: Container(
                      width: 48, height: 48,
                      decoration: const BoxDecoration(color: AppColors.online, shape: BoxShape.circle),
                      child: const Icon(Icons.send_rounded, color: Colors.white, size: 22),
                    ),
                  )
                else if (hasText)
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
                    onTap: onRecordStart,
                    child: Container(
                      width: 48, height: 48,
                      decoration: const BoxDecoration(color: AppColors.online, shape: BoxShape.circle),
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
