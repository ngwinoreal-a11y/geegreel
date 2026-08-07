import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/network/api_client.dart';
import 'notification_model.dart';

class NotificationsRepository {
  NotificationsRepository(this._dio);
  final Dio _dio;

  static const _cacheKey = 'notifications';

  List<NotificationModel>? readCached() {
    final raw = LocalCache.getMap(_cacheKey);
    if (raw == null) return null;
    return _parse(raw);
  }

  Future<(List<NotificationModel>, String?)> fetch({String? cursor}) async {
    final res = await _dio.get('/notifications', queryParameters: {
      if (cursor != null) 'cursor': cursor,
    });
    final data = res.data as Map<String, dynamic>;
    if (cursor == null) {
      await LocalCache.putJson(_cacheKey, data);
    }
    return (_parse(data), data['nextCursor'] as String?);
  }

  List<NotificationModel> _parse(Map<String, dynamic> data) {
    return (data['notifications'] as List<dynamic>? ?? [])
        .map((n) => NotificationModel.fromJson(n as Map<String, dynamic>))
        .toList();
  }

  Future<int> unreadCount() async {
    final res = await _dio.get('/notifications/unread-count');
    return ((res.data as Map<String, dynamic>)['count'] as num?)?.toInt() ?? 0;
  }

  Future<void> markAllRead() => _dio.post('/notifications/read');
}

final notificationsRepositoryProvider = Provider<NotificationsRepository>((ref) {
  return NotificationsRepository(ref.watch(dioProvider));
});

/// Instant-render-then-refresh (see LocalCache) — kept as `notificationsProvider`
/// so NotificationsScreen's `ref.watch(notificationsProvider)` didn't need to change.
class NotificationsController extends AsyncNotifier<List<NotificationModel>> {
  @override
  Future<List<NotificationModel>> build() async {
    final cached = ref.read(notificationsRepositoryProvider).readCached();
    if (cached != null) {
      Future.delayed(Duration.zero, _silentRefresh);
      return cached;
    }
    final (items, _) = await ref.read(notificationsRepositoryProvider).fetch();
    return items;
  }

  Future<void> _silentRefresh() async {
    try {
      final (items, _) = await ref.read(notificationsRepositoryProvider).fetch();
      state = AsyncData(items);
    } catch (_) {
      // Keep showing the cached list on a transient network failure.
    }
  }
}

final notificationsProvider =
    AsyncNotifierProvider<NotificationsController, List<NotificationModel>>(
        NotificationsController.new);
