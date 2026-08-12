import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/badges_provider.dart';
import '../../../core/widgets/bottom_nav_pill.dart';
import '../../../core/widgets/skeleton.dart';
import '../data/chat_repository.dart';
import '../data/message_model.dart';
import '../../../core/widgets/brand_refresh.dart';
import '../../notifications/data/notifications_repository.dart';
import 'activity_row.dart';

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
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Name, @username and the last message all match — looking for a
  /// conversation, you remember whichever of the three stuck.
  bool _matches(ThreadPreview t) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return t.user.displayName.toLowerCase().contains(q) ||
        t.user.username.toLowerCase().contains(q) ||
        (t.lastMessage ?? '').toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
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
        // Search sits in the app bar, above the list, so it's there the moment
        // Inbox opens instead of only after scrolling to the top.
        //
        // Every colour here is spelled out. This is a WHITE screen inside an
        // otherwise dark app, so an input that inherits the app's theme comes
        // out dark-on-light-grey with an invisible cursor — the same mistake
        // that has hidden text three times before.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v.trim()),
              textInputAction: TextInputAction.search,
              style: AppTypography.sans(fontSize: 15, color: AppColors.onChrome),
              cursorColor: AppColors.onChrome,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: AppColors.sheetFill,
                hintText: 'Search messages',
                hintStyle: AppTypography.sans(fontSize: 15, color: AppColors.onSheetMuted),
                prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.onSheetMuted),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18, color: AppColors.onSheetMuted),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
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
                final threads = allThreads
                    .where((t) => !t.isPendingRequestToMe)
                    .where(_matches)
                    .toList();
                if (_query.isNotEmpty && threads.isEmpty) {
                  return Center(
                    child: Text('No conversations match "$_query"',
                        style: AppTypography.sans(color: AppColors.onChromeMuted)),
                  );
                }
                // Index 0 is always the activity row — it isn't a conversation
                // and must not be sorted among them or disappear when there
                // are no messages yet. While searching it's hidden: it isn't a
                // result, and leaving it pinned above an empty list reads as a
                // match that isn't one.
                final showActivity = _query.isEmpty;
                return BrandRefresh(
                  onRefresh: () async {
                    ref.invalidate(inboxProvider);
                    ref.invalidate(notificationsProvider);
                    await ref.read(inboxProvider.future);
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: threads.length + (showActivity ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (showActivity) {
                        if (i == 0) return const ActivityRow();
                        return _ThreadRow(thread: threads[i - 1]);
                      }
                      return _ThreadRow(thread: threads[i]);
                    },
                  ),
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
                (icon: Icons.videocam, label: 'Shorts'),
              ],
              // The count belongs on the nav icon here too — the Activity row
              // showed 5 waiting while the Messages tab beneath it showed
              // nothing, so the badge that tells you to look was missing from
              // the one place you'd look next.
              badges: [ref.watch(unreadMessagesProvider).valueOrNull ?? 0, 0],
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
      // Sized to be read at arm's length on a phone — the previous 13px
      // preview was noticeably smaller than every other inbox people use.
      title: Text(thread.user.displayName,
          style: AppTypography.sans(
              fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.onChrome)),
      subtitle: Text(
        thread.lastMessage ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.sans(
          fontSize: 15,
          // An unread conversation reads darker and heavier, so the list says
          // what needs attention without a badge being the only signal.
          color: thread.unreadCount > 0 ? AppColors.onChrome : AppColors.onChromeMuted,
          fontWeight: thread.unreadCount > 0 ? FontWeight.w600 : FontWeight.w400,
        ),
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
