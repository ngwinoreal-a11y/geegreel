import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/user_model.dart';
import '../../feed/data/video_model.dart';
import '../../public_feed/data/post_model.dart';

/// One sound, as search returns it. Same fields the composer's picker gets —
/// the server sends one shape for both so the two cannot drift.
class SoundHit {
  const SoundHit({
    required this.id,
    required this.title,
    this.authorUsername,
    this.coverUrl,
    this.uses = 0,
  });

  final String id;
  final String title;
  final String? authorUsername;
  final String? coverUrl;
  final int uses;

  factory SoundHit.fromJson(Map<String, dynamic> j) => SoundHit(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? 'Sound',
        authorUsername: ((j['author'] as Map?)?['username']) as String?,
        coverUrl: j['coverUrl'] as String?,
        uses: (j['uses'] as num?)?.toInt() ?? 0,
      );
}

/// Everything one query turned up.
///
/// The screen used to render only [accounts] even though the API had always
/// sent videos and posts alongside them — so half of what the server found was
/// thrown away before anyone could see it.
class SearchResults {
  const SearchResults({
    this.accounts = const [],
    this.videos = const [],
    this.posts = const [],
    this.sounds = const [],
  });

  final List<UserModel> accounts;
  final List<VideoModel> videos;
  final List<PostModel> posts;
  final List<SoundHit> sounds;

  bool get isEmpty =>
      accounts.isEmpty && videos.isEmpty && posts.isEmpty && sounds.isEmpty;

  int get total => accounts.length + videos.length + posts.length + sounds.length;
}

/// `GET /api/search?q=` — see src/index.js.
class SearchRepository {
  SearchRepository(this._dio);
  final Dio _dio;

  Future<SearchResults> search(String query) async {
    if (query.trim().isEmpty) return const SearchResults();
    final res = await _dio.get('/search', queryParameters: {'q': query});
    final data = res.data as Map<String, dynamic>;

    List<T> parse<T>(String key, T Function(Map<String, dynamic>) make) =>
        ((data[key] as List<dynamic>?) ?? const [])
            .map((e) => make((e as Map).cast<String, dynamic>()))
            .toList();

    return SearchResults(
      accounts: parse('accounts', UserModel.fromJson),
      videos: parse('videos', VideoModel.fromJson),
      posts: parse('posts', PostModel.fromJson),
      sounds: parse('sounds', SoundHit.fromJson),
    );
  }
}

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(ref.watch(dioProvider));
});
