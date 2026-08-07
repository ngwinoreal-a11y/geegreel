import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../data/auth_repository.dart';
import '../data/user_model.dart';

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
      return await ref.read(authRepositoryProvider).me();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await ref.read(authTokenStorageProvider).clear();
        return null;
      }
      // Network hiccup — keep the token, report "unknown" as logged out for
      // this session but don't wipe credentials; next launch retries.
      return null;
    }
  }

  Future<void> login(String emailOrUsername, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final result = await ref
          .read(authRepositoryProvider)
          .login(emailOrUsername: emailOrUsername, password: password);
      await ref.read(authTokenStorageProvider).write(result.token);
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
      return result.user;
    });
  }

  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    await ref.read(authTokenStorageProvider).clear();
    state = const AsyncData(null);
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, UserModel?>(AuthController.new);

/// Convenience: true once we know for certain someone is logged in (not
/// while the initial /auth/me check is still in flight).
final isLoggedInProvider = Provider<bool>((ref) {
  return ref.watch(authControllerProvider).valueOrNull != null;
});
