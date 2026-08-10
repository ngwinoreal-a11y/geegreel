import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/application/auth_controller.dart';
import '../features/chat/data/chat_repository.dart';
import '../features/notifications/data/notifications_repository.dart';
import '../features/profile/data/profile_repository.dart';
import '../features/public_feed/data/public_feed_repository.dart';

/// Warms the on-device caches for the main screens right after the app opens,
/// in the background — so tapping into Public / Messages / Notifications /
/// Profile paints instantly from cache instead of showing a spinner on the
/// very first visit. Each fetch below writes to LocalCache as a side effect;
/// we just trigger them early.
///
/// Fire-and-forget and fully guarded: a failure (e.g. offline) never surfaces.
/// Throttled — repeat calls within [_cooldown] are ignored (so a home remount
/// doesn't re-fetch), but a later call (e.g. after signing in) warms again with
/// the now-authenticated endpoints. Call it from the home screen's initState.
DateTime? _lastPrewarm;
const _cooldown = Duration(seconds: 30);

void prewarmCaches(WidgetRef ref) {
  final now = DateTime.now();
  if (_lastPrewarm != null && now.difference(_lastPrewarm!) < _cooldown) return;
  _lastPrewarm = now;

  // Public feed is visible to everyone (even signed-out).
  _fire(() => ref.read(publicFeedRepositoryProvider).fetchPosts());

  if (ref.read(isLoggedInProvider)) {
    _fire(() => ref.read(notificationsRepositoryProvider).fetch());
    _fire(() => ref.read(chatRepositoryProvider).fetchInbox());
    final me = ref.read(authControllerProvider).valueOrNull;
    if (me != null) {
      _fire(() => ref.read(profileRepositoryProvider).fetchProfile(me.username));
    }
  }
}

/// Clears the throttle so the very next call warms immediately — handy right
/// after a login/logout so the new session's caches are rebuilt at once.
void resetPrewarm() => _lastPrewarm = null;

void _fire(Future<Object?> Function() task) {
  // Detached microtask: doesn't block the caller and swallows any error.
  Future<void>(() async {
    try {
      await task();
    } catch (_) {/* best-effort cache warming */}
  });
}
