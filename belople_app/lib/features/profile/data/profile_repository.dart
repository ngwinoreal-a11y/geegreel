import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/user_model.dart';
import '../../feed/data/video_model.dart';

class ProfileData {
  const ProfileData({
    required this.user,
    required this.following,
    required this.videos,
    required this.locked,
  });

  final UserModel user;
  final bool following;
  final List<VideoModel> videos;
  final bool locked;
}

/// `GET /api/users/:handle` — see src/index.js. Works by username or id.
class ProfileRepository {
  ProfileRepository(this._dio);
  final Dio _dio;

  static String _cacheKey(String handle) => 'profile_${handle.toLowerCase()}';

  ProfileData? readCachedProfile(String handle) {
    final raw = LocalCache.getMap(_cacheKey(handle));
    if (raw == null) return null;
    return _parse(raw);
  }

  Future<ProfileData> fetchProfile(String handle) async {
    final res = await _dio.get('/users/$handle');
    final data = res.data as Map<String, dynamic>;
    await LocalCache.putJson(_cacheKey(handle), data);
    return _parse(data);
  }

  ProfileData _parse(Map<String, dynamic> data) {
    final user = UserModel.fromJson(data['user'] as Map<String, dynamic>)
        .withStats(data['stats'] as Map<String, dynamic>?);
    final videos = (data['videos'] as List<dynamic>? ?? [])
        .map((v) => VideoModel.fromJson(v as Map<String, dynamic>))
        .toList();
    return ProfileData(
      user: user,
      following: data['following'] as bool? ?? false,
      videos: videos,
      locked: data['locked'] as bool? ?? false,
    );
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(dioProvider));
});

/// Instant-render-then-refresh, same pattern as FeedController — see
/// LocalCache's doc comment. Kept as `profileProvider` (not renamed) so
/// ProfileScreen's `ref.watch(profileProvider(handle))` didn't need to
/// change.
class ProfileController extends FamilyAsyncNotifier<ProfileData, String> {
  late String _handle;

  @override
  Future<ProfileData> build(String arg) async {
    _handle = arg;
    final cached = ref.read(profileRepositoryProvider).readCachedProfile(_handle);
    if (cached != null) {
      Future.delayed(Duration.zero, _silentRefresh);
      return cached;
    }
    return ref.read(profileRepositoryProvider).fetchProfile(_handle);
  }

  Future<void> _silentRefresh() async {
    try {
      final fresh = await ref.read(profileRepositoryProvider).fetchProfile(_handle);
      state = AsyncData(fresh);
    } catch (_) {
      // Keep showing the cached profile on a transient network failure.
    }
  }
}

final profileProvider =
    AsyncNotifierProvider.family<ProfileController, ProfileData, String>(ProfileController.new);
