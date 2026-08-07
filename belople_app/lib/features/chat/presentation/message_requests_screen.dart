import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import 'inbox_screen.dart';

/// Ports index.html's messageRequestsPage(): pending requests (from people
/// you don't follow back) filtered client-side from the inbox — see
/// message_model.dart's note on why accept/decline itself happens on the
/// Thread screen (the inbox response has no id for the other user, only
/// the thread fetch does).
class MessageRequestsScreen extends ConsumerWidget {
  const MessageRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inboxAsync = ref.watch(inboxProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Message requests')),
      body: inboxAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(
          child: Text("Couldn't load requests", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (threads) {
          final requests = threads.where((t) => t.isPendingRequestToMe).toList();
          if (requests.isEmpty) {
            return Center(child: Text('No pending requests', style: AppTypography.sans(color: AppColors.muted)));
          }
          return ListView.builder(
            itemCount: requests.length,
            itemBuilder: (context, i) {
              final thread = requests[i];
              return ListTile(
                onTap: () => context.push('/chat/${thread.user.username}'),
                leading: AppAvatar(
                  size: 46,
                  imageUrl: thread.user.avatarUrl != null ? mediaUrl(thread.user.avatarUrl!) : null,
                  displayName: thread.user.displayName,
                ),
                title: Text(thread.user.displayName, style: AppTypography.sans(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  thread.lastMessage ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sans(fontSize: 13, color: AppColors.muted),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
