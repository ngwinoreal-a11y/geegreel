import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../data/notification_model.dart';
import '../data/notifications_repository.dart';

/// Ports index.html's notificationsPage() + design-2.css section B: actor
/// avatar, message, relative time, and a right-aligned video thumbnail
/// (omitted for follow notifications).
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notificationsAsync = ref.watch(notificationsProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Notifications')),
      body: notificationsAsync.when(
        loading: () => ListView.builder(
          itemCount: 6,
          itemBuilder: (context, i) => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Skeleton.avatar(size: 46),
              SizedBox(width: 12),
              Expanded(child: Skeleton(height: 12)),
            ]),
          ),
        ),
        error: (e, _) => Center(
          child: Text("Couldn't load notifications", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Text('No notifications yet', style: AppTypography.sans(color: AppColors.muted)),
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => _NotificationRow(item: items[i]),
          );
        },
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.item});
  final NotificationModel item;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: item.read ? null : AppColors.unreadTint,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: GestureDetector(
        onTap: () => context.push('/profile/${item.actorUsername}'),
        child: Row(
          children: [
            AppAvatar(
              size: 46,
              imageUrl: item.actorAvatarUrl != null ? mediaUrl(item.actorAvatarUrl!) : null,
              displayName: item.actorDisplayName,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      style: AppTypography.sans(fontSize: 14, color: AppColors.text),
                      children: [
                        TextSpan(
                          text: item.actorDisplayName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: ' ${item.message}'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(_relativeTime(item.createdAt),
                      style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                ],
              ),
            ),
            if (item.videoThumb != null) ...[
              const SizedBox(width: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  mediaUrl(item.videoThumb!),
                  width: 44,
                  height: 56,
                  fit: BoxFit.cover,
                ),
              ),
            ],
          ],
        ),
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
