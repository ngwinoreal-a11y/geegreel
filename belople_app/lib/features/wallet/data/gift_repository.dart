import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

/// A gift the viewer can send on a video. Mirrors GIFTS in src/index.js; the
/// key is whitelisted server-side, so this list only needs to stay in sync
/// for display — the server rejects anything it doesn't know.
class Gift {
  const Gift({required this.key, required this.name, required this.coins, required this.emoji});
  final String key;
  final String name;
  final int coins;
  final String emoji;
}

const List<Gift> kGifts = [
  Gift(key: 'rose', name: 'Rose', coins: 2, emoji: '🌹'),
  Gift(key: 'heart', name: 'Heart', coins: 6, emoji: '❤️'),
  Gift(key: 'star', name: 'Star', coins: 10, emoji: '⭐'),
  Gift(key: 'fire', name: 'Fire', coins: 26, emoji: '🔥'),
  Gift(key: 'crown', name: 'Crown', coins: 50, emoji: '👑'),
  Gift(key: 'diamond', name: 'Diamond', coins: 100, emoji: '💎'),
  Gift(key: 'rocket', name: 'Rocket', coins: 500, emoji: '🚀'),
  Gift(key: 'trophy', name: 'Trophy', coins: 1000, emoji: '🏆'),
];

class GiftRepository {
  GiftRepository(this._dio);
  final Dio _dio;

  /// `POST /api/gifts` — spends coins server-side (atomic balance check) and
  /// returns the sender's remaining balance. Throws DioException with a 402
  /// when the viewer can't afford the gift.
  Future<int> sendGift({required String videoId, required String giftKey}) async {
    final res = await _dio.post('/gifts', data: {'videoId': videoId, 'giftKey': giftKey});
    return ((res.data as Map<String, dynamic>)['coinsLeft'] as num?)?.toInt() ?? 0;
  }
}

final giftRepositoryProvider = Provider<GiftRepository>((ref) {
  return GiftRepository(ref.watch(dioProvider));
});
