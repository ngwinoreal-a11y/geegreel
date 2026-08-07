import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../data/friends_repository.dart';

/// Ports index.html's followListPage() for a single kind (followers or
/// following) reached from a profile's stat row.
class FollowListScreen extends ConsumerWidget {
  const FollowListScreen({super.key, required this.handle, required this.kind});

  final String handle;
  final String kind; // 'followers' | 'following'

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(followListProvider((handle: handle, kind: kind)));

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(kind == 'followers' ? 'Followers' : 'Following')),
      body: listAsync.when(
        loading: () => ListView.builder(
          itemCount: 6,
          itemBuilder: (context, i) => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Skeleton.avatar(size: 44),
              SizedBox(width: 12),
              Expanded(child: Skeleton(height: 12)),
            ]),
          ),
        ),
        error: (e, _) => Center(
          child: Text("Couldn't load this list", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (users) {
          if (users.isEmpty) {
            return Center(child: Text('Nobody here yet', style: AppTypography.sans(color: AppColors.muted)));
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: users.length,
            itemBuilder: (context, i) {
              final u = users[i];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: AppAvatar(
                  size: 44,
                  imageUrl: u.avatarUrl != null ? mediaUrl(u.avatarUrl!) : null,
                  displayName: u.displayName,
                ),
                title: Text(u.displayName, style: AppTypography.sans(fontWeight: FontWeight.w600)),
                subtitle: Text('@${u.username}', style: AppTypography.sans(color: AppColors.muted, fontSize: 13)),
                onTap: () => context.push('/profile/${u.username}'),
              );
            },
          );
        },
      ),
    );
  }
}
