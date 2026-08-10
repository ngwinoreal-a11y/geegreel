import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../auth/application/auth_controller.dart';
import '../data/post_comment_model.dart';
import '../data/post_comment_repository.dart';

/// Comments on a Public post. design-public.css section E: this sheet is dark
/// (#1A1A1A), unlike the video feed's white comment sheet, because it opens
/// far more often and a white flash every time is fatiguing.
Future<void> showPostCommentsSheet(BuildContext context, {required String postId}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.publicSheetBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PostCommentsSheet(postId: postId),
  );
}

class _PostCommentsSheet extends ConsumerStatefulWidget {
  const _PostCommentsSheet({required this.postId});
  final String postId;

  @override
  ConsumerState<_PostCommentsSheet> createState() => _PostCommentsSheetState();
}

class _PostCommentsSheetState extends ConsumerState<_PostCommentsSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  List<PostComment>? _comments; // flat; nested into roots+replies at build time
  bool _posting = false;
  // Reply state + which threads are expanded (collapsed by default).
  PostComment? _replyTo;
  String? _replyToName;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final comments = await ref.read(postCommentRepositoryProvider).fetch(widget.postId);
      if (mounted) setState(() => _comments = comments);
    } catch (_) {
      if (mounted) setState(() => _comments = const []);
    }
  }

  Future<void> _post() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (!ref.read(isLoggedInProvider)) {
      context.push('/login');
      return;
    }
    setState(() => _posting = true);
    final replyRoot = _replyTo; // reply attaches to the root thread, one level deep
    try {
      final (comment, _) =
          await ref.read(postCommentRepositoryProvider).post(widget.postId, text, parentId: replyRoot?.id);
      _controller.clear();
      if (mounted) {
        setState(() {
          _comments = [...?_comments, comment];
          if (replyRoot != null) _expanded.add(replyRoot.id);
          _replyTo = null;
          _replyToName = null;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't post your comment")));
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  void _startReply(PostComment root, String name) {
    setState(() { _replyTo = root; _replyToName = name; });
    _focus.requestFocus();
  }

  void _cancelReply() => setState(() { _replyTo = null; _replyToName = null; });

  void _toggleReplies(String rootId) => setState(() {
        _expanded.contains(rootId) ? _expanded.remove(rootId) : _expanded.add(rootId);
      });

  /// Groups the flat comment list into root comments (preserving order) and a
  /// map of root-id -> its replies. Any reply whose parent is itself a reply is
  /// flattened up to its top-level root, keeping threads one level deep.
  (List<PostComment>, Map<String, List<PostComment>>) _thread() {
    final all = _comments ?? const <PostComment>[];
    final byId = {for (final c in all) c.id: c};
    String rootIdOf(PostComment c) {
      var cur = c;
      final seen = <String>{};
      while (cur.parentId != null && byId.containsKey(cur.parentId) && seen.add(cur.id)) {
        cur = byId[cur.parentId!]!;
      }
      return cur.id;
    }

    final roots = <PostComment>[];
    final repliesByRoot = <String, List<PostComment>>{};
    for (final c in all) {
      final rid = rootIdOf(c);
      if (rid == c.id) {
        roots.add(c); // top-level (or an orphan whose parent is gone)
      } else {
        (repliesByRoot[rid] ??= []).add(c);
      }
    }
    return (roots, repliesByRoot);
  }

  // Like/unlike by id — used for both root comments and replies (all live in
  // the flat _comments list).
  void _likeById(String id) {
    for (final c in _comments ?? const <PostComment>[]) {
      if (c.id == id) { _toggleLike(c); return; }
    }
  }

  Future<void> _toggleLike(PostComment comment) async {
    if (!ref.read(isLoggedInProvider)) {
      context.push('/login');
      return;
    }
    final want = !comment.liked;
    setState(() => _comments = [
          for (final c in _comments ?? const <PostComment>[])
            c.id == comment.id ? c.copyWith(liked: want, likes: c.likes + (want ? 1 : -1)) : c,
        ]);
    try {
      final (liked, count) =
          await ref.read(postCommentRepositoryProvider).setLiked(comment.id, want);
      if (mounted) {
        setState(() => _comments = [
              for (final c in _comments ?? const <PostComment>[])
                c.id == comment.id ? c.copyWith(liked: liked, likes: count) : c,
            ]);
      }
    } catch (_) {
      // Revert on failure.
      if (mounted) {
        setState(() => _comments = [
              for (final c in _comments ?? const <PostComment>[])
                c.id == comment.id ? comment : c,
            ]);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final comments = _comments;
    final (roots, repliesByRoot) = _thread();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (context, scrollController) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('Comments', style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: comments == null
                  ? const Center(child: CircularProgressIndicator(color: AppColors.text))
                  : comments.isEmpty
                      ? Center(
                          child: Text('No comments yet — be the first',
                              style: AppTypography.sans(color: AppColors.muted)))
                      : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          itemCount: roots.length,
                          itemBuilder: (context, i) {
                            final root = roots[i];
                            return _CommentRow(
                              comment: root,
                              replies: repliesByRoot[root.id] ?? const [],
                              expanded: _expanded.contains(root.id),
                              onToggleReplies: () => _toggleReplies(root.id),
                              onLike: _likeById,
                              onReply: (name) => _startReply(root, name),
                            );
                          },
                        ),
            ),
            SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyToName != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 10, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text('Replying to $_replyToName',
                                style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                          ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _cancelReply,
                            child: const Icon(Icons.close, size: 16, color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            style: AppTypography.sans(fontSize: 14),
                            minLines: 1,
                            maxLines: 4,
                            decoration: InputDecoration(
                                hintText: _replyToName != null ? 'Add a reply...' : 'Add a comment...'),
                          ),
                        ),
                        IconButton(
                          icon: _posting
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send_rounded, color: AppColors.send),
                          onPressed: _posting ? null : _post,
                        ),
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
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.replies,
    required this.expanded,
    required this.onToggleReplies,
    required this.onLike,
    required this.onReply,
  });
  final PostComment comment;
  final List<PostComment> replies;
  final bool expanded;
  final VoidCallback onToggleReplies;
  final void Function(String commentId) onLike;
  final void Function(String name) onReply;

  @override
  Widget build(BuildContext context) {
    final n = replies.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CommentContent(
          comment: comment,
          avatarSize: 34,
          onLike: () => onLike(comment.id),
          onReply: () => onReply(comment.user.displayName),
        ),
        if (n > 0)
          Padding(
            padding: const EdgeInsets.only(left: 44, bottom: 4),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleReplies,
              child: Row(
                children: [
                  Container(width: 22, height: 1, color: AppColors.border),
                  const SizedBox(width: 8),
                  Text(
                    expanded ? 'Hide replies' : 'View $n ${n == 1 ? 'reply' : 'replies'}',
                    style: AppTypography.sans(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ),
        if (expanded)
          for (final r in replies)
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: _CommentContent(
                comment: r,
                avatarSize: 28,
                onLike: () => onLike(r.id),
                onReply: () => onReply(r.user.displayName),
              ),
            ),
      ],
    );
  }
}

/// One public comment's content, reused for a root comment and its replies.
class _CommentContent extends StatelessWidget {
  const _CommentContent({
    required this.comment,
    required this.avatarSize,
    required this.onLike,
    required this.onReply,
  });
  final PostComment comment;
  final double avatarSize;
  final VoidCallback onLike;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            size: avatarSize,
            imageUrl: comment.user.avatarUrl != null ? mediaUrl(comment.user.avatarUrl!) : null,
            displayName: comment.user.displayName,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(comment.user.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.muted)),
                    ),
                    if (comment.user.verified) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.verified, color: AppColors.verified, size: 13),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(comment.body, style: AppTypography.sans(fontSize: 14)),
                const SizedBox(height: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onReply,
                  child: Text('Reply',
                      style: AppTypography.sans(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.muted)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onLike,
            behavior: HitTestBehavior.opaque,
            child: Column(
              children: [
                Icon(comment.liked ? Icons.favorite : Icons.favorite_border,
                    size: 18, color: comment.liked ? AppColors.badge : AppColors.muted),
                if (comment.likes > 0)
                  Text('${comment.likes}',
                      style: AppTypography.mono(fontSize: 11, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
