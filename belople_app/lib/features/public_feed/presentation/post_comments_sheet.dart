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
  List<PostComment>? _comments;
  bool _posting = false;

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
    try {
      final (comment, _) = await ref.read(postCommentRepositoryProvider).post(widget.postId, text);
      _controller.clear();
      if (mounted) setState(() => _comments = [...?_comments, comment]);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't post your comment")));
      }
    } finally {
      if (mounted) setState(() => _posting = false);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final comments = _comments;
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
                          itemCount: comments.length,
                          itemBuilder: (context, i) => _CommentRow(
                            comment: comments[i],
                            onLike: () => _toggleLike(comments[i]),
                          ),
                        ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        style: AppTypography.sans(fontSize: 14),
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(hintText: 'Add a comment...'),
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
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment, required this.onLike});
  final PostComment comment;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            size: 34,
            imageUrl: comment.user.avatarUrl != null ? mediaUrl(comment.user.avatarUrl!) : null,
            displayName: comment.user.displayName,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(comment.user.displayName,
                    style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.muted)),
                const SizedBox(height: 2),
                Text(comment.body, style: AppTypography.sans(fontSize: 14)),
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
