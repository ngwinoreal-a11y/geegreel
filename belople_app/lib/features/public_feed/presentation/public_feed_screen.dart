import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../application/public_feed_controller.dart';
import '../data/post_model.dart';

/// Ports public.js's mountPublic(): an Instagram-like photo feed. The
/// video-spliced-in-every-3-posts behavior is deferred — this covers the
/// photo-post rendering/like/infinite-scroll path end to end.
class PublicFeedScreen extends ConsumerStatefulWidget {
  const PublicFeedScreen({super.key});

  @override
  ConsumerState<PublicFeedScreen> createState() => _PublicFeedScreenState();
}

class _PublicFeedScreenState extends ConsumerState<PublicFeedScreen> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 800) {
      ref.read(publicFeedControllerProvider.notifier).loadMore();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(publicFeedControllerProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Public')),
      body: feedAsync.when(
        loading: () => ListView.builder(
          itemCount: 3,
          itemBuilder: (context, i) => const _PostSkeleton(),
        ),
        error: (e, _) => Center(
          child: Text("Couldn't load posts", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (state) {
          if (state.posts.isEmpty) {
            return Center(child: Text('No posts yet', style: AppTypography.sans(color: AppColors.muted)));
          }
          return ListView.builder(
            controller: _scrollController,
            itemCount: state.posts.length,
            itemBuilder: (context, i) => _PostCard(
              post: state.posts[i],
              onLikeTap: () =>
                  ref.read(publicFeedControllerProvider.notifier).toggleLike(state.posts[i].id),
            ),
          );
        },
      ),
    );
  }
}

class _PostCard extends ConsumerWidget {
  const _PostCard({required this.post, required this.onLikeTap});
  final PostModel post;
  final VoidCallback onLikeTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.publicPostPadding, vertical: 10),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => context.push('/profile/${post.user.username}'),
                  child: AppAvatar(
                    size: 32,
                    imageUrl: post.user.avatarUrl != null ? mediaUrl(post.user.avatarUrl!) : null,
                    displayName: post.user.displayName,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () => context.push('/profile/${post.user.username}'),
                    child: Text(post.user.displayName,
                        style: AppTypography.sans(fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                ),
                if (!post.following)
                  Text('Follow', style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.verified)),
              ],
            ),
          ),
          if (post.imageUrl != null)
            AspectRatio(
              aspectRatio: post.aspectRatio,
              child: Image.network(mediaUrl(post.imageUrl!), fit: BoxFit.contain, width: double.infinity),
            )
          else if (post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.publicPostPadding),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
                child: Text(post.content, style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 12, AppSpacing.publicPostPadding, 0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    if (!ref.read(isLoggedInProvider)) {
                      context.push('/login');
                    } else {
                      onLikeTap();
                    }
                  },
                  child: Row(children: [
                    Icon(post.liked ? Icons.favorite : Icons.favorite_border,
                        color: post.liked ? AppColors.badge : AppColors.text, size: 26),
                    const SizedBox(width: 7),
                    Text('${post.likes}', style: AppTypography.mono(fontSize: 15)),
                  ]),
                ),
                const SizedBox(width: 20),
                Icon(Icons.mode_comment_outlined, color: AppColors.text, size: 24),
                const SizedBox(width: 7),
                Text('${post.comments}', style: AppTypography.mono(fontSize: 15)),
                const SizedBox(width: 20),
                const Icon(Icons.reply_rounded, color: AppColors.text, size: 24),
                const SizedBox(width: 7),
                Text('${post.shares}', style: AppTypography.mono(fontSize: 15)),
              ],
            ),
          ),
          if (post.imageUrl != null && post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 10, AppSpacing.publicPostPadding, 0),
              child: Text(post.content, style: AppTypography.sans(fontSize: 15)),
            ),
        ],
      ),
    );
  }
}

class _PostSkeleton extends StatelessWidget {
  const _PostSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          const AspectRatio(aspectRatio: 4 / 5, child: Skeleton(borderRadius: 0)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: const [
              Skeleton(width: 80, height: 12),
            ]),
          ),
        ],
      ),
    );
  }
}
