import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/linkified_text.dart';
import '../../auth/application/auth_controller.dart';
import '../data/post_model.dart';
import '../data/public_feed_repository.dart';
import 'post_comments_sheet.dart';

/// A single Public post opened from a profile grid — so tapping a specific post
/// shows THAT post (not the top of the public feed). Rendered from the
/// PostModel passed in `extra`, so it opens instantly.
class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.post});
  final PostModel post;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  late bool _liked = widget.post.liked;
  late int _likes = widget.post.likes;
  late int _shares = widget.post.shares;

  Future<void> _toggleLike() async {
    if (!ref.read(isLoggedInProvider)) { context.push('/login'); return; }
    final want = !_liked;
    setState(() { _liked = want; _likes += want ? 1 : -1; });
    try {
      final (liked, count) = await ref.read(publicFeedRepositoryProvider).setLiked(widget.post.id, want);
      if (mounted) setState(() { _liked = liked; _likes = count; });
    } catch (_) {
      if (mounted) setState(() { _liked = !want; _likes += want ? -1 : 1; });
    }
  }

  Future<void> _share() async {
    try {
      await Share.share('$kApiBaseUrl/p/${widget.post.id}', subject: 'Belople post');
      final count = await ref.read(publicFeedRepositoryProvider).sharePost(widget.post.id);
      if (mounted) setState(() => _shares = count);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    // Dark, matching the Public feed it was opened from and the web's own
    // Public page. (This screen was briefly white to match a white feed; both
    // are dark now, which is what design-public.css does.)
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.text,
        elevation: 0,
        title: const Text('Post'),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => context.push('/profile/${post.user.username}'),
                  child: AppAvatar(
                    size: 38,
                    ring: true,
                    imageUrl: post.user.avatarUrl != null ? mediaUrl(post.user.avatarUrl!) : null,
                    displayName: post.user.displayName,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(post.user.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.sans(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.text)),
                      ),
                      if (post.user.verified) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.verified, color: AppColors.verified, size: 15),
                      ],
                      const SizedBox(width: 8),
                      Text(_timeAgo(post.createdAt),
                          style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (post.imageUrl != null)
            // Reserve the post's real aspect ratio (as the feed does) so the
            // image has a height before it loads — a bare CachedNetworkImage in
            // a ListView collapsed to zero height until the bytes arrived,
            // which also read as "nothing showed".
            AspectRatio(
              aspectRatio: post.aspectRatio,
              child: CachedNetworkImage(imageUrl: mediaUrl(post.imageUrl!), fit: BoxFit.contain, width: double.infinity),
            )
          else if (post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
                child: LinkifiedText(text: post.content, style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.text)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleLike,
                  child: Row(children: [
                    Icon(_liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: _liked ? AppColors.badge : AppColors.text, size: 26),
                    const SizedBox(width: 7),
                    Text('$_likes', style: AppTypography.mono(fontSize: 15, color: AppColors.text)),
                  ]),
                ),
                const SizedBox(width: 20),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showPostCommentsSheet(context, postId: post.id),
                  child: Row(children: [
                    const Icon(Icons.mode_comment_outlined, color: AppColors.text, size: 24),
                    const SizedBox(width: 7),
                    Text('${post.comments}', style: AppTypography.mono(fontSize: 15, color: AppColors.text)),
                  ]),
                ),
                const SizedBox(width: 20),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _share,
                  child: Row(children: [
                    const Icon(Icons.send_rounded, color: AppColors.text, size: 23),
                    const SizedBox(width: 7),
                    Text('$_shares', style: AppTypography.mono(fontSize: 15, color: AppColors.text)),
                  ]),
                ),
              ],
            ),
          ),
          // Caption below an image post — the feed shows this too, so a photo
          // post keeps its text here instead of dropping it.
          if (post.imageUrl != null && post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: LinkifiedText(text: post.content, style: AppTypography.sans(fontSize: 15, color: AppColors.text)),
            ),
        ],
      ),
    );
  }
}

String _timeAgo(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  if (d.inDays < 30) return '${(d.inDays / 7).floor()}w';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo';
  return '${(d.inDays / 365).floor()}y';
}
