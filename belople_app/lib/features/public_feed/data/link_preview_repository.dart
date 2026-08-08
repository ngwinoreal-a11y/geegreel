import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

class LinkPreview {
  const LinkPreview({required this.url, required this.title, this.description, this.image, this.siteName});
  final String url;
  final String title;
  final String? description;
  final String? image;
  final String? siteName;

  factory LinkPreview.fromJson(Map<String, dynamic> json) => LinkPreview(
        url: json['url'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String?,
        image: json['image'] as String?,
        siteName: json['siteName'] as String?,
      );
}

/// `GET /api/link-preview?url=` — server-side OpenGraph scrape. Cached per URL
/// for the session so scrolling the feed doesn't refetch the same preview.
class LinkPreviewRepository {
  LinkPreviewRepository(this._dio);
  final Dio _dio;
  final Map<String, LinkPreview?> _cache = {};

  Future<LinkPreview?> fetch(String url) async {
    if (_cache.containsKey(url)) return _cache[url];
    try {
      final res = await _dio.get('/link-preview', queryParameters: {'url': url});
      final preview = LinkPreview.fromJson(res.data as Map<String, dynamic>);
      _cache[url] = preview;
      return preview;
    } catch (_) {
      _cache[url] = null;
      return null;
    }
  }
}

final linkPreviewRepositoryProvider = Provider<LinkPreviewRepository>((ref) {
  return LinkPreviewRepository(ref.watch(dioProvider));
});

final linkPreviewProvider = FutureProvider.family.autoDispose<LinkPreview?, String>((ref, url) {
  return ref.watch(linkPreviewRepositoryProvider).fetch(url);
});
