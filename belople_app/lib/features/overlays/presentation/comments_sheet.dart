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
  List<CommentModel>? _comments;
  bool _loading = true;
  bool _sending = false;
  String? _error;

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

  Future<void> _reactToComment(int index) async {
    if (!ref.read(isLoggedInProvider) || _comments == null) return;
    final comment = _comments![index];
    final wasLiked = comment.myReaction == 'like';
    // Optimistic flip; reconciled below with the server's authoritative
    // counts once the (toggle) request completes — see comment_repository's
    // react() doc: sending 'like' again is what clears it server-side.
    setState(() => _comments![index] = comment.copyWith(
          myReaction: wasLiked ? null : 'like',
          likes: comment.likes + (wasLiked ? -1 : 1),
        ));
    try {
      final (likes, _, myReaction) = await ref.read(commentRepositoryProvider).react(comment.id, 'like');
      if (mounted) {
        setState(() => _comments![index] = comment.copyWith(likes: likes, myReaction: myReaction));
      }
    } catch (_) {
      if (mounted) setState(() => _comments![index] = comment);
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    if (!ref.read(isLoggedInProvider)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _sending = true);
    try {
      final (comment, _) = await ref.read(commentRepositoryProvider).postComment(widget.videoId, text);
      setState(() {
        _comments = [comment, ...?_comments];
        _controller.clear();
        _sending = false;
      });
    } catch (_) {
      setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
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
                              itemBuilder: (context, i) => _CommentRow(
                                comment: _comments![i],
                                onReact: () => _reactToComment(i),
                              ),
                            ),
            ),
            _Composer(controller: _controller, sending: _sending, onSend: _send),
          ],
        );
      },
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment, this.onReact});
  final CommentModel comment;
  final VoidCallback? onReact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            size: 36,
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
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '${comment.user.displayName}  ',
                        style: AppTypography.sans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSheetMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(comment.body, style: AppTypography.sans(fontSize: 14, color: AppColors.sheetInk)),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Text(_relativeTime(comment.createdAt),
                        style: AppTypography.sans(fontSize: 12, color: AppColors.onSheetMuted)),
                    const SizedBox(width: 14),
                    if (comment.likes > 0)
                      Text('${comment.likes} likes',
                          style: AppTypography.sans(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.onSheetMuted,
                          )),
                  ],
                ),
                if (comment.replies.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('View ${comment.replies.length} replies',
                        style: AppTypography.sans(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSheetMuted,
                        )),
                  ),
              ],
            ),
          ),
          GestureDetector(
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
  const _Composer({required this.controller, required this.sending, required this.onSend});
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: const BoxDecoration(
          color: AppColors.sheetBg,
          border: Border(top: BorderSide(color: AppColors.sheetLine)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                style: AppTypography.sans(fontSize: 14, color: AppColors.sheetInk),
                decoration: InputDecoration(
                  hintText: 'Add a comment...',
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
    );
  }
}
