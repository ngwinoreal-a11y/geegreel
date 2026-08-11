import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

/// A gift the viewer can send on a video. Mirrors GIFTS in src/index.js; the
/// key is whitelisted server-side, so this list only needs to stay in sync
/// for display — the server rejects anything it doesn't know.
class Gift {
  const Gift({
    required this.key,
    required this.name,
    required this.coins,
    required this.emoji,
    this.brand = false,
  });
  final String key;
  final String name;
  final int coins;
  final String emoji;

  /// Belople's own gift — rendered with the app's mark and accent instead of
  /// a plain emoji tile.
  final bool brand;
}

/// Must match GIFTS in src/index.js key-for-key and price-for-price: the server
/// charges from ITS list, so a mismatch would show one price and bill another.
const List<Gift> kGifts = [
  Gift(key: 'heart', name: 'Heart', coins: 2, emoji: '❤️'),
  Gift(key: 'rose', name: 'Rose', coins: 5, emoji: '🌹'),
  Gift(key: 'star', name: 'Star', coins: 10, emoji: '⭐'),
  Gift(key: 'clap', name: 'Applause', coins: 20, emoji: '👏'),
  Gift(key: 'fire', name: 'Fire', coins: 30, emoji: '🔥'),
  Gift(key: 'crown', name: 'Crown', coins: 50, emoji: '👑'),
  Gift(key: 'diamond', name: 'Diamond', coins: 100, emoji: '💎'),
  Gift(key: 'cake', name: 'Cake', coins: 200, emoji: '🎂'),
  Gift(key: 'rocket', name: 'Rocket', coins: 500, emoji: '🚀'),
  Gift(key: 'trophy', name: 'Trophy', coins: 1000, emoji: '🏆'),
  Gift(key: 'belople', name: 'Belople', coins: 2000, emoji: '⚡', brand: true),
  Gift(key: 'car', name: 'Car', coins: 5000, emoji: '🚗'),
  Gift(key: 'ring', name: 'Ring', coins: 10000, emoji: '💍'),
  Gift(key: 'yacht', name: 'Yacht', coins: 30000, emoji: '🛥️'),
  Gift(key: 'jet', name: 'Jet', coins: 40000, emoji: '✈️'),
  Gift(key: 'castle', name: 'Castle', coins: 50000, emoji: '🏰'),
  Gift(key: 'island', name: 'Island', coins: 100000, emoji: '🏝️'),
  Gift(key: 'galaxy', name: 'Galaxy', coins: 200000, emoji: '🌌'),
  Gift(key: 'universe', name: 'Universe', coins: 500000, emoji: '🌠'),
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
