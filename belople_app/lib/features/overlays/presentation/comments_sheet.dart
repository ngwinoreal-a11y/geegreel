import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../data/comment_model.dart';
import '../data/comment_repository.dart';

/// Ports design.css section 8/9 + design-3.css section J: a white sheet
/// (unlike the rest of the dark app — see design-3.css's rationale) with a
/// scrollable comment list and a composer.
Future<void> showCommentsSheet(BuildContext context, {required String videoId}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.sheetBg,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (context) => _CommentsSheet(videoId: videoId),
  );
}

class _CommentsSheet extends ConsumerStatefulWidget {
  const _CommentsSheet({required this.videoId});
  final String videoId;

  @override
  ConsumerState<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<_CommentsSheet> {
  final _controller = TextEditingController();
  final _inputFocus = FocusNode();
  List<CommentModel>? _comments;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  // Reply state: the root thread being replied to + the name we show/prefill.
  CommentModel? _replyTo;
  String? _replyToName;
  // Threads whose replies are currently expanded (collapsed by default).
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (comments, _) = await ref.read(commentRepositoryProvider).fetchComments(widget.videoId);
      if (mounted) setState(() { _comments = comments; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = "Couldn't load comments"; _loading = false; });
    }
  }

  // Finds a comment by id, searching both roots and their one-level replies.
  CommentModel? _find(String id) {
    for (final root in _comments ?? const <CommentModel>[]) {
      if (root.id == id) return root;
      for (final r in root.replies) {
        if (r.id == id) return r;
      }
    }
    return null;
  }

  // Immutably swaps a comment (root or reply) for an updated copy.
  void _replaceComment(String id, CommentModel updated) {
    _comments = _comments!.map((root) {
      if (root.id == id) return updated;
      if (root.replies.any((r) => r.id == id)) {
        return root.copyWith(
          myReaction: root.myReaction, // preserve — copyWith would otherwise clear
          replies: root.replies.map((r) => r.id == id ? updated : r).toList(),
        );
      }
      return root;
    }).toList();
  }

  // Like/unlike any comment or reply, reconciled with the server's counts.
  Future<void> _react(String id) async {
    if (!ref.read(isLoggedInProvider)) return;
    final c = _find(id);
    if (c == null) return;
    final wasLiked = c.myReaction == 'like';
    setState(() => _replaceComment(id, c.copyWith(
          myReaction: wasLiked ? null : 'like',
          likes: c.likes + (wasLiked ? -1 : 1),
        )));
    try {
      final (likes, _, myReaction) = await ref.read(commentRepositoryProvider).react(id, 'like');
      if (mounted) setState(() => _replaceComment(id, (_find(id) ?? c).copyWith(likes: likes, myReaction: myReaction)));
    } catch (_) {
      if (mounted) setState(() => _replaceComment(id, c));
    }
  }

  void _startReply(CommentModel root, String name) {
    setState(() { _replyTo = root; _replyToName = name; });
    _inputFocus.requestFocus();
  }

  void _cancelReply() => setState(() { _replyTo = null; _replyToName = null; });

  void _toggleReplies(String rootId) => setState(() {
        _expanded.contains(rootId) ? _expanded.remove(rootId) : _expanded.add(rootId);
      });

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    if (!ref.read(isLoggedInProvider)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _sending = true);
    final replyRoot = _replyTo; // backend nests replies one level, under the root
    try {
      final (comment, _) = await ref
          .read(commentRepositoryProvider)
          .postComment(widget.videoId, text, parentId: replyRoot?.id);
      if (!mounted) return;
      setState(() {
        if (replyRoot != null) {
          _comments = _comments!
              .map((root) => root.id == replyRoot.id
                  ? root.copyWith(myReaction: root.myReaction, replies: [...root.replies, comment])
                  : root)
              .toList();
          _expanded.add(replyRoot.id); // reveal the thread we just added to
        } else {
          _comments = [comment, ...?_comments];
        }
        _controller.clear();
        _replyTo = null;
        _replyToName = null;
        _sending = false;
      });
    } catch (_) {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.68,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.sheetLine)),
              ),
              child: Center(
                child: Text('Comments', style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.sheetInk)),
              ),
            ),
            Expanded(
              child: _loading
                  ? ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: 4,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(children: const [
                          Skeleton.avatar(size: 36, onSheet: true),
                          SizedBox(width: 10),
                          Expanded(child: Skeleton(height: 12, onSheet: true)),
                        ]),
                      ),
                    )
                  : _error != null
                      ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.sheetMuted)))
                      : (_comments?.isEmpty ?? true)
                          ? Center(
                              child: Text('No comments yet',
                                  style: AppTypography.sans(color: AppColors.sheetMuted)))
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: _comments!.length,
                              itemBuilder: (context, i) {
                                final root = _comments![i];
                                return _CommentRow(
                                  comment: root,
                                  expanded: _expanded.contains(root.id),
                                  onToggleReplies: () => _toggleReplies(root.id),
                                  onReact: _react,
                                  onReply: (name) => _startReply(root, name),
                                );
                              },
                            ),
            ),
            _Composer(
              controller: _controller,
              focusNode: _inputFocus,
              sending: _sending,
              onSend: _send,
              replyingToName: _replyToName,
              onCancelReply: _cancelReply,
            ),
          ],
        );
      },
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.expanded,
    required this.onToggleReplies,
    required this.onReact,
    required this.onReply,
  });
  final CommentModel comment;
  final bool expanded;
  final VoidCallback onToggleReplies;
  final void Function(String commentId) onReact;
  final void Function(String name) onReply;

  @override
  Widget build(BuildContext context) {
    final n = comment.replies.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CommentContent(
          comment: comment,
          avatarSize: 36,
          onReact: () => onReact(comment.id),
          onReply: () => onReply(comment.user.displayName),
        ),
        // Replies are collapsed by default — a tappable "View N replies" line;
        // tapping reveals the thread (or hides it again).
        if (n > 0)
          Padding(
            padding: const EdgeInsets.only(left: 62, bottom: 6),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleReplies,
              child: Row(
                children: [
                  Container(width: 22, height: 1, color: AppColors.sheetLine),
                  const SizedBox(width: 8),
                  Text(
                    expanded ? 'Hide replies' : 'View $n ${n == 1 ? 'reply' : 'replies'}',
                    style: AppTypography.sans(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.onSheetMuted),
                  ),
                ],
              ),
            ),
          ),
        if (expanded)
          for (final r in comment.replies)
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: _CommentContent(
                comment: r,
                avatarSize: 28,
                onReact: () => onReact(r.id),
                onReply: () => onReply(r.user.displayName),
              ),
            ),
      ],
    );
  }
}

/// One comment's content (avatar + name + body + time / Reply / like), reused
/// for both a root comment and its indented replies via [avatarSize].
class _CommentContent extends StatelessWidget {
  const _CommentContent({
    required this.comment,
    required this.avatarSize,
    required this.onReact,
    required this.onReply,
  });
  final CommentModel comment;
  final double avatarSize;
  final VoidCallback onReact;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            size: avatarSize,
            imageUrl: comment.user.avatarUrl != null ? mediaUrl(comment.user.avatarUrl!) : null,
            displayName: comment.user.displayName,
            backgroundColor: const Color(0xFFE4E4E6),
            textColor: const Color(0xFF55555A),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(comment.user.displayName,
                    style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.onSheetMuted)),
                Text(comment.body, style: AppTypography.sans(fontSize: 14, color: AppColors.sheetInk)),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Text(_relativeTime(comment.createdAt),
                        style: AppTypography.sans(fontSize: 12, color: AppColors.onSheetMuted)),
                    const SizedBox(width: 16),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onReply,
                      child: Text('Reply',
                          style: AppTypography.sans(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.onSheetMuted)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onReact,
            child: Padding(
              padding: const EdgeInsets.only(top: 3, left: 8),
              child: Column(
                children: [
                  Icon(
                    comment.myReaction == 'like' ? Icons.favorite : Icons.favorite_border,
                    size: 16,
                    color: comment.myReaction == 'like' ? AppColors.danger : AppColors.onSheetMuted,
                  ),
                  if (comment.likes > 0) ...[
                    const SizedBox(height: 2),
                    Text('${comment.likes}', style: const TextStyle(fontSize: 11, color: AppColors.onSheetMuted)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${(diff.inDays / 7).floor()}w';
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    this.focusNode,
    this.replyingToName,
    this.onCancelReply,
  });
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final FocusNode? focusNode;
  final String? replyingToName;
  final VoidCallback? onCancelReply;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.sheetBg,
          border: Border(top: BorderSide(color: AppColors.sheetLine)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // "Replying to @name" banner, with a way to cancel back to a
            // top-level comment.
            if (replyingToName != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Replying to $replyingToName',
                          style: AppTypography.sans(fontSize: 12, color: AppColors.onSheetMuted)),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onCancelReply,
                      child: const Icon(Icons.close, size: 16, color: AppColors.onSheetMuted),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      style: AppTypography.sans(fontSize: 14, color: AppColors.sheetInk),
                      decoration: InputDecoration(
                        hintText: replyingToName != null ? 'Add a reply...' : 'Add a comment...',
                        hintStyle: AppTypography.sans(fontSize: 14, color: AppColors.onSheetMuted),
                        filled: true,
                        fillColor: AppColors.sheetFill,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => onSend(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: sending ? null : onSend,
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: sending ? const Color(0xFFD8D8DA) : AppColors.sheetInk,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      alignment: Alignment.center,
                      child: Text('Send',
                          style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
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
}
