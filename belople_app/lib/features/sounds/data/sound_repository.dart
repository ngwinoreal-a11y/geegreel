import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../feed/data/video_model.dart';

class SoundModel {
  const SoundModel({
    required this.id,
    required this.title,
    this.author,
    this.uses = 0,
    this.audioUrl,
    this.coverUrl,
    this.duration,
    this.sourceCaption,
  });
  final String id;
  final String title;
  final String? author;
  final int uses;

  /// `/api/media/:key` path to the sound's audio — needed to mix the sound
  /// into a recorded video at upload time. Present on the single-sound detail.
  final String? audioUrl;

  /// The source video's thumbnail, standing in as the sound's cover art. A
  /// column of identical note glyphs told you nothing about what you'd get.
  final String? coverUrl;

  /// Seconds, from the source video — a sound's length is its video's length.
  final double? duration;

  /// The source video's caption. Every sound is titled "Original sound -
  /// <username>" because nothing ever asks the poster for a name, so this is
  /// what actually tells two of them apart.
  final String? sourceCaption;

  /// "0:51". Null when the backend has no duration for the source video.
  String? get durationLabel {
    final d = duration;
    if (d == null || d <= 0) return null;
    final total = d.round();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

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
        coverUrl: json['coverUrl'] as String?,
        duration: (json['duration'] as num?)?.toDouble(),
        sourceCaption: json['sourceCaption'] as String?,
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

  /// `GET /api/sounds/search?q=` — for the composer's "Add sound" picker. An
  /// empty query is allowed and returns the most-used sounds, so the sheet has
  /// something to show before you know what to type.
  ///
  /// fromJson already handles the nested author object and every other field,
  /// so this no longer hand-maps a subset and silently drops the cover, the
  /// duration and the audio url on the floor.
  Future<List<SoundModel>> search(String query) async {
    final res = await _dio.get('/sounds/search', queryParameters: {'q': query});
    final data = res.data as Map<String, dynamic>;
    return (data['sounds'] as List<dynamic>? ?? [])
        .map((s) => SoundModel.fromJson(s as Map<String, dynamic>))
        .toList();
  }
}

final soundRepositoryProvider = Provider<SoundRepository>((ref) {
  return SoundRepository(ref.watch(dioProvider));
});

final soundProvider = FutureProvider.family.autoDispose<SoundDetail, String>((ref, id) {
  return ref.watch(soundRepositoryProvider).fetch(id);
});
