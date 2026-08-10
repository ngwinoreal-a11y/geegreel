import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/chat/data/chat_repository.dart';
import '../features/notifications/data/notifications_repository.dart';

/// Polls the unread message count (~5s) so the Messages tab badge updates
/// near-real-time without the user refreshing. Yields 0 while logged out
/// rather than hammering the API with 401s.
final unreadMessagesProvider = StreamProvider<int>((ref) async* {
  while (true) {
    if (ref.read(isLoggedInProvider)) {
      try {
        yield await ref.read(chatRepositoryProvider).unreadCount();
      } catch (_) {
        yield 0;
      }
    } else {
      yield 0;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// Polls the unread notification count (~20s) for the profile bell badge.
final unreadNotificationsProvider = StreamProvider<int>((ref) async* {
  while (true) {
    if (ref.read(isLoggedInProvider)) {
      try {
        yield await ref.read(notificationsRepositoryProvider).unreadCount();
      } catch (_) {
        yield 0;
      }
    } else {
      yield 0;
    }
    await Future<void>.delayed(const Duration(seconds: 20));
  }
});
