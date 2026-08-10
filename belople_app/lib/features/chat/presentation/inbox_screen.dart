import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/bottom_nav_pill.dart';
import '../../../core/widgets/skeleton.dart';
import '../data/chat_repository.dart';
import '../data/message_model.dart';

/// Instant-render-then-refresh (see LocalCache doc comment): shows the last
/// known thread list immediately instead of a spinner, then quietly
/// replaces it with a live fetch.
class InboxController extends AutoDisposeAsyncNotifier<List<ThreadPreview>> {
  @override
  Future<List<ThreadPreview>> build() async {
    // Poll every 5s while the inbox is on screen so new messages and unread
    // counts appear live — no pull-to-refresh needed.
    final timer = Timer.periodic(const Duration(seconds: 5), (_) => _silentRefresh());
    ref.onDispose(timer.cancel);

    final cached = ref.read(chatRepositoryProvider).readCachedInbox();
    if (cached != null) {
      Future.delayed(Duration.zero, _silentRefresh);
      return cached;
    }
    return ref.read(chatRepositoryProvider).fetchInbox();
  }

  Future<void> _silentRefresh() async {
    try {
      final fresh = await ref.read(chatRepositoryProvider).fetchInbox();
      state = AsyncData(fresh);
    } catch (_) {
      // Keep showing the cached inbox on a transient network failure.
    }
  }
}

final inboxProvider =
    AsyncNotifierProvider.autoDispose<InboxController, List<ThreadPreview>>(InboxController.new);

/// Ports index.html's messagesPage(): thread list, unread badges,
/// online-dot presence. Like the web (`.page.msgs-page { background:#fff }`)
/// the inbox is a deliberate white break from the app's dark theme, headed by
/// a big "Inbox" title (h2: 28px/800) instead of the brand wordmark.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inboxAsync = ref.watch(inboxProvider);

    final pendingCount = inboxAsync.valueOrNull?.where((t) => t.isPendingRequestToMe).length ?? 0;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: AppColors.onChrome,
        elevation: 0,
        titleSpacing: 16,
        title: Text('Inbox',
            style: AppTypography.display(fontSize: 28, fontWeight: FontWeight.w800, color: AppColors.onChrome)),
        actions: [
          IconButton(
            icon: Badge(
              label: Text('$pendingCount'),
              isLabelVisible: pendingCount > 0,
              child: const Icon(Icons.person_add_alt_outlined),
            ),
            onPressed: () => context.push('/message-requests'),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: inboxAsync.when(
              loading: () => ListView.builder(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: 6,
                itemBuilder: (context, i) => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    Skeleton.avatar(size: 50),
                    SizedBox(width: 12),
                    Expanded(child: Skeleton(height: 12)),
                  ]),
                ),
              ),
              error: (e, _) => Center(
                child: Text("Couldn't load messages", style: AppTypography.sans(color: AppColors.onChromeMuted)),
              ),
              data: (allThreads) {
                final threads = allThreads.where((t) => !t.isPendingRequestToMe).toList();
                if (threads.isEmpty) {
                  return Center(child: Text('No messages yet', style: AppTypography.sans(color: AppColors.onChromeMuted)));
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: threads.length,
                  itemBuilder: (context, i) => _ThreadRow(thread: threads[i]),
                );
              },
            ),
          ),
          // Messages-mode nav: FAB morphs to "add friend" here instead of
          // "post" — mirrors attachNav()'s isMsg branch in index.html, which
          // this screen previously didn't render at all.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: BottomNavPill(
              items: const [
                (icon: Icons.mail_outline, label: 'Messages'),
                (icon: Icons.videocam, label: 'Feed'),
              ],
              activeIndex: 0,
              onTap: (i) {
                // Feed/home: pop back to the live Feed underneath (reached
                // here via push) so its video resumes, instead of go('/')
                // which tears down the stack and rebuilds a fresh feed.
                if (i == 1) {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/');
                  }
                }
              },
              fabIcon: Icons.person_add_alt_1,
              onFabTap: () => context.push('/friends'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow({required this.thread});
  final ThreadPreview thread;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => context.push('/chat/${thread.user.username}'),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          AppAvatar(
            size: 50,
            imageUrl: thread.user.avatarUrl != null ? mediaUrl(thread.user.avatarUrl!) : null,
            displayName: thread.user.displayName,
          ),
          if (thread.online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: AppColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
              ),
            ),
        ],
      ),
      title: Text(thread.user.displayName,
          style: AppTypography.sans(fontWeight: FontWeight.w600, color: AppColors.onChrome)),
      subtitle: Text(
        thread.lastMessage ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.sans(fontSize: 13, color: AppColors.onChromeMuted),
      ),
      trailing: thread.unreadCount > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: AppColors.badge, borderRadius: BorderRadius.circular(10)),
              child: Text('${thread.unreadCount}',
                  style: AppTypography.sans(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
            )
          : null,
    );
  }
}
