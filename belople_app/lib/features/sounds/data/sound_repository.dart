import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../feed/data/video_model.dart';

class SoundModel {
  const SoundModel({required this.id, required this.title, this.author, this.uses = 0, this.audioUrl});
  final String id;
  final String title;
  final String? author;
  final int uses;

  /// `/api/media/:key` path to the sound's audio — needed to mix the sound
  /// into a recorded video at upload time. Present on the single-sound detail.
  final String? audioUrl;

  factory SoundModel.fromJson(Map<String, dynamic> json) => SoundModel(
        id: json['id'].toString(),
        title: json['title'] as String? ?? 'Original sound',
        // `/api/sounds/:id` returns author as an OBJECT ({id, username,
        // displayName, …}); older/other shapes may send a plain name string.
        // Casting the object straight to String? threw and surfaced as
        // "Couldn't load this sound" for every valid sound.
        author: json['author'] is Map
            ? (json['author'] as Map<String, dynamic>)['displayName'] as String?
            : json['author'] as String?,
        uses: (json['uses'] as num?)?.toInt() ?? 0,
        audioUrl: json['audioUrl'] as String?,
      );
}

class SoundDetail {
  const SoundDetail({required this.sound, required this.videos});
  final SoundModel sound;
  final List<VideoModel> videos;
}

/// `GET /api/sounds/:id` — see src/index.js.
class SoundRepository {
  SoundRepository(this._dio);
  final Dio _dio;

  Future<SoundDetail> fetch(String id) async {
    final res = await _dio.get('/sounds/$id');
    final data = res.data as Map<String, dynamic>;
    return SoundDetail(
      sound: SoundModel.fromJson(data['sound'] as Map<String, dynamic>),
      videos: (data['videos'] as List<dynamic>? ?? [])
          .map((v) => VideoModel.fromJson(v as Map<String, dynamic>))
          .toList(),
    );
  }

  /// `GET /api/sounds/search?q=` — for the composer's "Add sound" picker.
  /// The search response nests author as an object, so map it down to the
  /// display name SoundModel expects.
  Future<List<SoundModel>> search(String query) async {
    final res = await _dio.get('/sounds/search', queryParameters: {'q': query});
    final data = res.data as Map<String, dynamic>;
    return (data['sounds'] as List<dynamic>? ?? []).map((s) {
      final json = s as Map<String, dynamic>;
      return SoundModel(
        id: json['id'].toString(),
        title: json['title'] as String? ?? 'Sound',
        author: (json['author'] as Map<String, dynamic>?)?['displayName'] as String?,
        uses: (json['uses'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }
}

final soundRepositoryProvider = Provider<SoundRepository>((ref) {
  return SoundRepository(ref.watch(dioProvider));
});

final soundProvider = FutureProvider.family.autoDispose<SoundDetail, String>((ref, id) {
  return ref.watch(soundRepositoryProvider).fetch(id);
});
