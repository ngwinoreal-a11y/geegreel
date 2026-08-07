import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

class WalletData {
  const WalletData({
    required this.coins,
    required this.giftBalanceCents,
    required this.lifetimeGiftsCents,
    required this.giftsReceived,
    required this.giftsSent,
  });

  final int coins;
  final int giftBalanceCents;
  final int lifetimeGiftsCents;
  final int giftsReceived;
  final int giftsSent;

  factory WalletData.fromJson(Map<String, dynamic> json) => WalletData(
        coins: (json['coins'] as num?)?.toInt() ?? 0,
        giftBalanceCents: (json['giftBalanceCents'] as num?)?.toInt() ?? 0,
        lifetimeGiftsCents: (json['lifetimeGiftsCents'] as num?)?.toInt() ?? 0,
        giftsReceived: (json['giftsReceived'] as num?)?.toInt() ?? 0,
        giftsSent: (json['giftsSent'] as num?)?.toInt() ?? 0,
      );
}

/// `GET /api/wallet` — see src/index.js. Buying coins is intentionally not
/// wired here: the web app punts that flow out to the system browser on
/// Android (Play Billing policy — see `isAndroidTWA()` in index.html) and
/// the plan carries the same constraint into the Flutter app (Phase 5).
class WalletRepository {
  WalletRepository(this._dio);
  final Dio _dio;

  Future<WalletData> fetch() async {
    final res = await _dio.get('/wallet');
    return WalletData.fromJson(res.data as Map<String, dynamic>);
  }
}

final walletRepositoryProvider = Provider<WalletRepository>((ref) {
  return WalletRepository(ref.watch(dioProvider));
});

final walletProvider = FutureProvider.autoDispose((ref) {
  return ref.watch(walletRepositoryProvider).fetch();
});
