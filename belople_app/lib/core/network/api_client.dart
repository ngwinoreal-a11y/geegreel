import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Belople's Cloudflare Worker backend. Same API the web app
/// (video-app.ngwinoreal.workers.dev / belople.com) talks to — see
/// src/index.js. Every endpoint is prefixed with /api.
const String kApiBaseUrl = 'https://video-app.ngwinoreal.workers.dev';

const _secureStorage = FlutterSecureStorage();
const _tokenKey = 'belople_session_token';

/// Reads/writes the opaque bearer session token the same way the web app's
/// `store.token` (localStorage) does — see index.html's `api()` helper and
/// src/index.js's `getUserByToken`. 30-day server-side expiry; no refresh
/// token concept, just re-login when it expires.
class AuthTokenStorage {
  const AuthTokenStorage();

  Future<String?> read() => _secureStorage.read(key: _tokenKey);
  Future<void> write(String token) => _secureStorage.write(key: _tokenKey, value: token);
  Future<void> clear() => _secureStorage.delete(key: _tokenKey);
}

final authTokenStorageProvider = Provider<AuthTokenStorage>((ref) => const AuthTokenStorage());

/// Dio instance wired with the base URL and an interceptor that attaches
/// `Authorization: Bearer <token>` to every request, mirroring index.html's
/// `api()` fetch wrapper.
final dioProvider = Provider<Dio>((ref) {
  final storage = ref.watch(authTokenStorageProvider);
  final dio = Dio(BaseOptions(
    baseUrl: '$kApiBaseUrl/api',
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
  ));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final token = await storage.read();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      handler.next(options);
    },
  ));
  return dio;
});

/// Builds a full URL for an R2-backed media path returned by the API (every
/// videoUrl/avatarUrl/thumbUrl field is a `/api/media/:key` path) — see
/// `GET /api/media/:key` in src/index.js.
String mediaUrl(String path) {
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  return '$kApiBaseUrl$path';
}
