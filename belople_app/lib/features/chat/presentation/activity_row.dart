import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/badges_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../notifications/data/notifications_repository.dart';

/// The pinned row at the top of the inbox that gathers everything that isn't a
/// message — likes, comments, follows, reposts, gifts, new videos.
///
/// It sits above the threads and never scrolls out of that position, because
/// it isn't a conversation: it's the one place all other activity collects.
/// Its subtitle is the most recent of those events, so the row says what
/// happened without being opened.
class ActivityRow extends ConsumerWidget {
  const ActivityRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationsProvider).valueOrNull ?? 0;
    final latest = ref.watch(notificationsProvider).valueOrNull;
    final subtitle = (latest != null && latest.isNotEmpty)
        ? '${latest.first.actorDisplayName} ${latest.first.message}'
        : 'Likes, comments, follows and new videos';

    return InkWell(
      onTap: () => context.push('/notifications'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Belople's accent rather than a photo — this row stands for the
            // app itself, not a person, so it must not read as a contact.
            Container(
              width: 50,
              height: 50,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.bolt_rounded, color: AppColors.onAccent, size: 28),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The inbox is a WHITE surface, so this needs the dark ink —
                  // it was inheriting the dark theme's white and was invisible
                  // against the background.
                  Text(
                    'Activity & new followers',
                    style: AppTypography.sans(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: AppColors.onChrome,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.sans(
                      fontSize: 15,
                      color: unread > 0 ? AppColors.onChrome : AppColors.onChromeMuted,
                      fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            if (unread > 0) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                constraints: const BoxConstraints(minWidth: 20),
                decoration: BoxDecoration(
                  color: AppColors.badge,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  textAlign: TextAlign.center,
                  style: AppTypography.sans(
                    fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
