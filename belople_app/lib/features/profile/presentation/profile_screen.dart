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
import '../data/profile_repository.dart';

/// Ports index.html's profilePage(): avatar/bio/stats, Edit-profile (self)
/// or Follow+Message (other), video grid. Read-only for Phase 1 — edit
/// profile / message lands with Settings (Phase 2) and Chat (Phase 3).
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key, required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileProvider(handle));
    final me = ref.watch(authControllerProvider).valueOrNull;

    final isSelf = me != null && me.username.toLowerCase() == handle.toLowerCase();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('@$handle'),
        actions: isSelf
            ? [
                IconButton(
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  onPressed: () => context.push('/wallet'),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => context.push('/settings'),
                ),
              ]
            : null,
      ),
      body: profileAsync.when(
        loading: () => const _ProfileSkeleton(),
        error: (err, _) => Center(
          child: Text("Couldn't load this profile", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (profile) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageHorizontal, 20, AppSpacing.pageHorizontal, 0,
                  ),
                  child: Column(
                    children: [
                      AppAvatar(
                        size: 88,
                        imageUrl: profile.user.avatarUrl != null
                            ? mediaUrl(profile.user.avatarUrl!)
                            : null,
                        displayName: profile.user.displayName,
                      ),
                      const SizedBox(height: 10),
                      Text(profile.user.displayName, style: AppTypography.pageHeading.copyWith(fontSize: 18)),
                      Text('@${profile.user.username}',
                          style: AppTypography.sans(color: AppColors.muted, fontSize: 13)),
                      if (profile.user.bio != null && profile.user.bio!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(profile.user.bio!, style: AppTypography.sans(fontSize: 14), textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          GestureDetector(
                            onTap: () => context.push('/profile/$handle/following'),
                            child: _Stat(label: 'Following', value: profile.user.followingCount),
                          ),
                          GestureDetector(
                            onTap: () => context.push('/profile/$handle/followers'),
                            child: _Stat(label: 'Followers', value: profile.user.followersCount),
                          ),
                          _Stat(label: 'Likes', value: profile.user.likesCount),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (!isSelf)
                        ElevatedButton(
                          onPressed: () {},
                          child: Text(profile.following ? 'Following' : 'Follow'),
                        ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
              if (profile.locked)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(
                      child: Text('This account is private', style: TextStyle(color: AppColors.muted)),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 3,
                      crossAxisSpacing: 3,
                      childAspectRatio: 9 / 14,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final video = profile.videos[index];
                        return GestureDetector(
                          onTap: () => context.push('/v/${video.id}'),
                          child: DecoratedBox(
                            decoration: const BoxDecoration(color: AppColors.raised),
                            child: video.thumbUrl != null
                                ? Image.network(mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                                : null,
                          ),
                        );
                      },
                      childCount: profile.videos.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$value', style: AppTypography.statNumber),
        Text(label, style: AppTypography.statLabel),
      ],
    );
  }
}

class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppSpacing.pageHorizontal),
      child: Column(
        children: [
          Skeleton.avatar(size: 88),
          SizedBox(height: 16),
          Skeleton(width: 140, height: 14),
        ],
      ),
    );
  }
}
