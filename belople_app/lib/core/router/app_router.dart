import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_screen.dart';
import '../../features/camera/presentation/composer_screen.dart';
import '../../features/chat/presentation/inbox_screen.dart';
import '../../features/chat/presentation/message_requests_screen.dart';
import '../../features/chat/presentation/thread_screen.dart';
import '../../features/feed/presentation/feed_screen.dart';
import '../../features/feed/presentation/single_video_screen.dart';
import '../../features/friends/presentation/follow_list_screen.dart';
import '../../features/friends/presentation/friends_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/overlays/presentation/component_gallery_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/public_feed/presentation/public_feed_screen.dart';
import '../../features/search/presentation/search_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/sounds/presentation/sound_screen.dart';
import '../../features/wallet/presentation/buy_coins_screen.dart';
import '../../features/wallet/presentation/monetization_screen.dart';
import '../../features/wallet/presentation/wallet_history_screen.dart';
import '../../features/wallet/presentation/wallet_screen.dart';

/// go_router config. The full shell route (persistent bottom nav across
/// Feed/Public/Chat/Profile) is deferred — FeedScreen renders its own
/// bottom nav inline for now.
///
/// Deep links: `/v/:id` is a real route, matched automatically once the
/// Android App Links intent-filter (AndroidManifest.xml) hands the path
/// through. The web app's query-param-style deep links
/// (`?video=`, `?user=`, `?chat=`, `?open=wallet` — see index.html's
/// `handleDeepLink()`) arrive on `/` instead, since that's the URL shape
/// shared links/notifications use; the `redirect` below translates those
/// into the equivalent named routes on first launch.
/// Lets FeedScreen know when another screen has been pushed on top of it
/// (single video, profile, comments-as-a-route, etc.) so it can pause the
/// currently-playing slide instead of leaving its audio running underneath
/// a screen the user can no longer see it on.
final routeObserver = RouteObserver<PageRoute<dynamic>>();

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    observers: [routeObserver],
    initialLocation: '/',
    redirect: (context, state) {
      if (state.matchedLocation != '/') return null;
      final params = state.uri.queryParameters;
      if (params['video'] != null) return '/v/${params['video']}';
      if (params['user'] != null) return '/profile/${params['user']}';
      if (params['chat'] != null) return '/chat/${params['chat']}';
      if (params['open'] == 'wallet') return '/wallet';
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const FeedScreen(),
      ),
      GoRoute(
        path: '/gallery',
        builder: (context, state) => const ComponentGalleryScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: '/profile/:handle',
        builder: (context, state) => ProfileScreen(handle: state.pathParameters['handle']!),
      ),
      GoRoute(
        path: '/profile/:handle/:kind',
        builder: (context, state) => FollowListScreen(
          handle: state.pathParameters['handle']!,
          kind: state.pathParameters['kind']!,
        ),
      ),
      GoRoute(
        path: '/public',
        builder: (context, state) => const PublicFeedScreen(),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => const SearchScreen(),
      ),
      GoRoute(
        path: '/notifications',
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/wallet',
        builder: (context, state) => const WalletScreen(),
      ),
      GoRoute(
        path: '/wallet/history',
        builder: (context, state) => const WalletHistoryScreen(),
      ),
      GoRoute(
        path: '/coins',
        builder: (context, state) => const BuyCoinsScreen(),
      ),
      GoRoute(
        path: '/monetization',
        builder: (context, state) => const MonetizationScreen(),
      ),
      GoRoute(
        path: '/messages',
        builder: (context, state) => const InboxScreen(),
      ),
      GoRoute(
        path: '/message-requests',
        builder: (context, state) => const MessageRequestsScreen(),
      ),
      GoRoute(
        path: '/friends',
        builder: (context, state) => const FriendsScreen(),
      ),
      GoRoute(
        path: '/chat/:username',
        builder: (context, state) => ThreadScreen(username: state.pathParameters['username']!),
      ),
      GoRoute(
        path: '/v/:id',
        builder: (context, state) => SingleVideoScreen(videoId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/sound/:id',
        builder: (context, state) => SoundScreen(soundId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/compose',
        builder: (context, state) =>
            ComposerScreen(soundId: state.uri.queryParameters['sound']),
      ),
    ],
  );
});
