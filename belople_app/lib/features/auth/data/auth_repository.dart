import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import 'user_model.dart';

class AuthResult {
  const AuthResult({required this.token, required this.user});
  final String token;
  final UserModel user;
}

/// Wraps `POST /api/auth/signup|login|logout` and `GET /api/auth/me` — see
/// src/index.js. Session tokens are opaque bearer strings, not JWT; the
/// interceptor in api_client.dart attaches whatever's in secure storage.
class AuthRepository {
  AuthRepository(this._dio);
  final Dio _dio;

  Future<AuthResult> login({required String emailOrUsername, required String password}) async {
    final res = await _dio.post('/auth/login', data: {
      'email': emailOrUsername,
      'password': password,
    });
    return _parseAuthResult(res.data as Map<String, dynamic>);
  }

  Future<AuthResult> signup({
    required String username,
    required String email,
    required String password,
    String? displayName,
    String? country,
    String? city,
    List<String>? interests,
  }) async {
    final res = await _dio.post('/auth/signup', data: {
      'username': username,
      'email': email,
      'password': password,
      if (displayName != null) 'displayName': displayName,
      if (country != null) 'country': country,
      if (city != null) 'city': city,
      if (interests != null) 'interests': interests,
    });
    return _parseAuthResult(res.data as Map<String, dynamic>);
  }

  Future<UserModel> me() async {
    final res = await _dio.get('/auth/me');
    final data = res.data as Map<String, dynamic>;
    return UserModel.fromJson(data['user'] as Map<String, dynamic>);
  }

  Future<void> logout() async {
    try {
      await _dio.post('/auth/logout');
    } catch (_) {
      // Best-effort — token gets cleared client-side regardless.
    }
  }

  AuthResult _parseAuthResult(Map<String, dynamic> data) {
    return AuthResult(
      token: data['token'] as String,
      user: UserModel.fromJson(data['user'] as Map<String, dynamic>),
    );
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(dioProvider));
});
