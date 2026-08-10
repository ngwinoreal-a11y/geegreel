import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/network/api_client.dart';
import '../data/auth_repository.dart';
import '../data/user_model.dart';

/// Last known signed-in user, kept so an offline cold start stays logged in
/// instead of bouncing to the login screen.
const _userCacheKey = 'auth_user';

/// Session state. Mirrors index.html's boot IIFE: on cold start, if a token
/// is in storage, verify it against `GET /api/auth/me`; only clear it on a
/// genuine 401 (not on a network failure, to avoid false logouts offline —
/// see the summary of index.html's boot sequence).
class AuthController extends AsyncNotifier<UserModel?> {
  @override
  Future<UserModel?> build() async {
    final token = await ref.read(authTokenStorageProvider).read();
    if (token == null || token.isEmpty) return null;
    try {
      final user = await ref.read(authRepositoryProvider).me();
      await LocalCache.putJson(_userCacheKey, user.toJson());
      return user;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // Genuinely signed out server-side — clear everything.
        await ref.read(authTokenStorageProvider).clear();
        await LocalCache.remove(_userCacheKey);
        return null;
      }
      // Offline / network hiccup: stay signed in with the last known user so
      // the app doesn't kick you to the login screen just because there's no
      // internet. The token is untouched; next launch re-verifies.
      final cached = LocalCache.getMap(_userCacheKey);
      return cached != null ? UserModel.fromJson(cached) : null;
    }
  }

  Future<void> login(String emailOrUsername, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final result = await ref
          .read(authRepositoryProvider)
          .login(emailOrUsername: emailOrUsername, password: password);
      await ref.read(authTokenStorageProvider).write(result.token);
      await LocalCache.putJson(_userCacheKey, result.user.toJson());
      return result.user;
    });
  }

  Future<void> signup({
    required String username,
    required String email,
    required String password,
    String? displayName,
    String? country,
    String? city,
    List<String>? interests,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final result = await ref.read(authRepositoryProvider).signup(
            username: username,
            email: email,
            password: password,
            displayName: displayName,
            country: country,
            city: city,
            interests: interests,
          );
      await ref.read(authTokenStorageProvider).write(result.token);
      await LocalCache.putJson(_userCacheKey, result.user.toJson());
      return result.user;
    });
  }

  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    await ref.read(authTokenStorageProvider).clear();
    await LocalCache.remove(_userCacheKey);
    state = const AsyncData(null);
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, UserModel?>(AuthController.new);

/// Convenience: true once we know for certain someone is logged in (not
/// while the initial /auth/me check is still in flight).
final isLoggedInProvider = Provider<bool>((ref) {
  return ref.watch(authControllerProvider).valueOrNull != null;
});
