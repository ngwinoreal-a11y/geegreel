import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_screen.dart';
import '../../features/auth/presentation/google_signin_screen.dart';
import '../../features/camera/presentation/camera_capture_screen.dart';
import '../../features/camera/presentation/composer_screen.dart';
import '../../features/chat/presentation/inbox_screen.dart';
import '../../features/chat/presentation/message_requests_screen.dart';
import '../../features/chat/presentation/thread_screen.dart';
import '../../features/feed/data/video_model.dart';
import '../../features/feed/presentation/feed_screen.dart';
import '../../features/feed/presentation/single_video_screen.dart';
import '../../features/friends/presentation/follow_list_screen.dart';
import '../../features/friends/presentation/friends_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/overlays/presentation/component_gallery_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/profile/presentation/profile_videos_screen.dart';
import '../../features/promote/presentation/admin_ads_screen.dart';
import '../../features/promote/presentation/my_ads_screen.dart';
import '../../features/promote/presentation/promote_screen.dart';
import '../../features/public_feed/presentation/post_detail_screen.dart';
import '../../features/public_feed/presentation/public_feed_screen.dart';
import '../../features/public_feed/data/post_model.dart';
import '../../features/search/presentation/search_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/sounds/presentation/sound_screen.dart';
import '../../features/wallet/presentation/monetization_screen.dart';
import '../../features/wallet/presentation/cash_out_screen.dart';
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

/// A fast cross-fade page used for every route, so screens feel like they
/// snap open rather than sliding in over ~300ms (the user asked for quick
/// navigation). Keeps go_router's back-swipe/observer behaviour intact.
CustomTransitionPage<void> _fast(LocalKey key, Widget child) {
  return CustomTransitionPage<void>(
    key: key,
    transitionDuration: const Duration(milliseconds: 130),
    reverseTransitionDuration: const Duration(milliseconds: 110),
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

GoRoute _route(String path, Widget Function(BuildContext, GoRouterState) build) {
  return GoRoute(
    path: path,
    pageBuilder: (context, state) => _fast(state.pageKey, build(context, state)),
  );
}

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
      _route('/', (context, state) => const FeedScreen()),
      _route('/gallery', (context, state) => const ComponentGalleryScreen()),
      _route('/login', (context, state) => const AuthScreen()),
      _route('/google-signin', (context, state) => const GoogleSignInScreen()),
      _route('/profile/:handle',
          (context, state) => ProfileScreen(handle: state.pathParameters['handle']!)),
      _route(
          '/profile/:handle/:kind',
          (context, state) => FollowListScreen(
                handle: state.pathParameters['handle']!,
                kind: state.pathParameters['kind']!,
              )),
      _route('/public', (context, state) => const PublicFeedScreen()),
      _route('/search', (context, state) => const SearchScreen()),
      _route('/notifications', (context, state) => const NotificationsScreen()),
      _route('/settings', (context, state) => const SettingsScreen()),
      _route('/wallet', (context, state) => const WalletScreen()),
      _route('/wallet/history', (context, state) => const WalletHistoryScreen()),
      _route('/wallet/cash-out', (context, state) => const CashOutScreen()),
      // No '/coins' route. Coins are bought on the website: Google Play
      // requires in-app purchases of digital goods to go through Play Billing
      // and forbids the app from pointing anywhere else. The screen it opened
      // is deleted rather than left unrouted — an orphaned file is how the last
      // one got forgotten about — and git has it for when Play Billing goes in.
      _route('/monetization', (context, state) => const MonetizationScreen()),
      _route('/messages', (context, state) => const InboxScreen()),
      _route('/message-requests', (context, state) => const MessageRequestsScreen()),
      _route('/friends', (context, state) => const FriendsScreen()),
      _route('/chat/:username',
          (context, state) => ThreadScreen(username: state.pathParameters['username']!)),
      _route('/v/:id',
          (context, state) => SingleVideoScreen(
                videoId: state.pathParameters['id']!,
                // Set by a comment/reply notification, whose action button says
                // "Reply" — it must land somewhere you can actually reply.
                openComments: state.uri.queryParameters['comments'] == '1',
                // When opened from a grid we already hold the full VideoModel;
                // passing it renders the player instantly instead of showing a
                // spinner while a redundant fetch runs.
                initialVideo: state.extra is VideoModel ? state.extra as VideoModel : null,
              )),
      _route('/sound/:id',
          (context, state) => SoundScreen(soundId: state.pathParameters['id']!)),
      // A single Public post (opened from a profile grid). Needs the PostModel
      // in `extra`; a bare deep link falls back to the full public feed.
      _route('/p/:id', (context, state) => state.extra is PostModel
          ? PostDetailScreen(post: state.extra as PostModel)
          : const PublicFeedScreen()),
      // A swipeable feed of one profile's videos, starting at the tapped one.
      _route('/profile-videos', (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final videos = (extra?['videos'] as List?)?.cast<VideoModel>() ?? const [];
        return ProfileVideosScreen(videos: videos, initialIndex: (extra?['index'] as int?) ?? 0);
      }),
      _route('/compose', (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return ComposerScreen(
          soundId: state.uri.queryParameters['sound'],
          videoPath: extra?['videoPath'] as String?,
          imagePath: extra?['imagePath'] as String?,
          initialMode: extra?['mode'] as String?,
        );
      }),
      _route('/camera', (context, state) => const CameraCaptureScreen()),
      _route('/promote', (context, state) => const PromoteScreen()),
      _route('/my-ads', (context, state) => const MyAdsScreen()),
      _route('/admin/ads', (context, state) => const AdminAdsScreen()),
    ],
  );
});
