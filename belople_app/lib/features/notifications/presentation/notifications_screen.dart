import 'package:cached_network_image/cached_network_image.dart';
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
/// avatar (tap → their profile), bold-name message, relative time, and a
/// right-aligned video thumbnail. Tapping the row opens the video (or the
/// profile for a follow); opening the list clears the unread badge.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // Opening the list marks everything read, same as TikTok's inbox — clears
    // the bell badge.
    ref.read(notificationsRepositoryProvider).markAllRead().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.notifications_none, color: AppColors.faint, size: 56),
                  const SizedBox(height: 12),
                  Text('Nothing yet', style: AppTypography.sans(color: AppColors.muted, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text('Likes, comments and follows will show up here.',
                      style: AppTypography.sans(color: AppColors.faint, fontSize: 13)),
                ],
              ),
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

  void _openProfile(BuildContext context) => context.push('/profile/${item.actorUsername}');

  void _openRow(BuildContext context) {
    // The avatar means "that person"; the row means "the thing they did".
    switch (item.type) {
      case 'follow':
        _openProfile(context);
      case 'message':
        context.push('/chat/${item.actorUsername}');
      // A comment or reply opens the video WITH the comments up — landing on
      // the video and leaving the reader to find the comment they were told
      // about is most of the way to the thing, but not the thing.
      case 'comment' || 'reply' when item.videoId != null:
        context.push('/v/${item.videoId}?comments=1');
      default:
        if (item.videoId != null) {
          context.push('/v/${item.videoId}');
        } else {
          _openProfile(context);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openRow(context),
      child: Container(
        color: item.read ? null : AppColors.unreadTint,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openProfile(context),
              child: AppAvatar(
                size: 46,
                imageUrl: item.actorAvatarUrl != null ? mediaUrl(item.actorAvatarUrl!) : null,
                displayName: item.actorDisplayName,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      style: AppTypography.sans(fontSize: 16, color: AppColors.text),
                      children: item.isAnnouncement
                          // An announcement is from Belople, not from a person
                          // doing something to you — so it reads as the message
                          // itself under the app's name, and never as
                          // "<admin's display name> <verb>".
                          ? [
                              const TextSpan(
                                  text: 'Belople  ',
                                  style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.accent)),
                              TextSpan(text: item.message),
                            ]
                          : [
                              TextSpan(text: item.actorDisplayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                              TextSpan(text: ' ${item.message}'),
                            ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(_relativeTime(item.createdAt),
                      style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
                ],
              ),
            ),
            if (item.videoThumb != null) ...[
              const SizedBox(width: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: mediaUrl(item.videoThumb!),
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
