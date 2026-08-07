import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/user_model.dart';

/// `GET /api/users/:handle/followers|following`, `GET /api/friends/suggested`,
/// `POST/DELETE /api/users/:id/follow` — see src/index.js.
class FriendsRepository {
  FriendsRepository(this._dio);
  final Dio _dio;

  Future<List<UserModel>> fetchList(String handle, String kind) async {
    final res = await _dio.get('/users/$handle/$kind');
    final data = res.data as Map<String, dynamic>;
    return (data['users'] as List<dynamic>? ?? [])
        .map((u) => UserModel.fromJson(u as Map<String, dynamic>))
        .toList();
  }

  /// "Friends" tab on the Friends screen — no separate mutuals concept on
  /// the backend, a mutual is anyone in my followers I also follow back
  /// (mirrors friendsPage()'s "friends" tab in index.html).
  Future<List<UserModel>> fetchMutuals(String me) async {
    final followers = await fetchList(me, 'followers');
    return followers.where((u) => u.following).toList();
  }

  Future<List<UserModel>> fetchSuggested() async {
    final res = await _dio.get('/friends/suggested');
    final data = res.data as Map<String, dynamic>;
    return (data['users'] as List<dynamic>? ?? [])
        .map((u) => UserModel.fromJson(u as Map<String, dynamic>))
        .toList();
  }

  Future<bool> setFollowing(String userId, bool following) async {
    final res = following
        ? await _dio.post('/users/$userId/follow')
        : await _dio.delete('/users/$userId/follow');
    final data = res.data as Map<String, dynamic>;
    return data['following'] as bool? ?? following;
  }
}

final friendsRepositoryProvider = Provider<FriendsRepository>((ref) {
  return FriendsRepository(ref.watch(dioProvider));
});

final followListProvider = FutureProvider.family
    .autoDispose<List<UserModel>, ({String handle, String kind})>((ref, args) {
  return ref.watch(friendsRepositoryProvider).fetchList(args.handle, args.kind);
});
