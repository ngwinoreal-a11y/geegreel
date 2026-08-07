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

/// One wallet ledger entry (a gift sent/received, a coin purchase, an
/// earnings payout…). Mirrors the `wallet_tx` rows /api/wallet/history returns.
class WalletTx {
  const WalletTx({
    required this.kind,
    required this.coinsDelta,
    required this.centsDelta,
    this.note,
    required this.createdAt,
  });

  final String kind;
  final int coinsDelta;
  final int centsDelta;
  final String? note;
  final int createdAt;

  factory WalletTx.fromJson(Map<String, dynamic> json) => WalletTx(
        kind: json['kind'] as String? ?? '',
        coinsDelta: (json['coinsDelta'] as num?)?.toInt() ?? 0,
        centsDelta: (json['centsDelta'] as num?)?.toInt() ?? 0,
        note: json['note'] as String?,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// The fixed coin packs the buy-coins sheet offers (COIN_PACKS in index.js).
/// `cents` is the price in USD cents.
class CoinPack {
  const CoinPack(this.coins, this.cents);
  final int coins;
  final int cents;
}

const List<CoinPack> kCoinPacks = [
  CoinPack(100, 100),
  CoinPack(500, 500),
  CoinPack(1000, 1000),
  CoinPack(5000, 5000),
];

/// `GET /api/wallet`, `GET /api/wallet/history`, `POST /api/coins/buy` — see
/// src/index.js. A coin purchase is recorded as *pending*; an admin confirms
/// the real-world payment (there's no in-app payment processor), matching the
/// web app's own flow.
class WalletRepository {
  WalletRepository(this._dio);
  final Dio _dio;

  Future<WalletData> fetch() async {
    final res = await _dio.get('/wallet');
    return WalletData.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<WalletTx>> fetchHistory() async {
    final res = await _dio.get('/wallet/history');
    final data = res.data as Map<String, dynamic>;
    return (data['history'] as List<dynamic>? ?? [])
        .map((t) => WalletTx.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  /// Records a pending coin purchase. `method` is how the user says they paid
  /// (e.g. "MTN MoMo"), `reference` an optional transaction id.
  Future<void> buyCoins({required int coins, required String method, String? reference}) {
    return _dio.post('/coins/buy', data: {
      'coins': coins,
      'method': method,
      if (reference != null && reference.isNotEmpty) 'reference': reference,
    });
  }
}

final walletRepositoryProvider = Provider<WalletRepository>((ref) {
  return WalletRepository(ref.watch(dioProvider));
});

final walletProvider = FutureProvider.autoDispose((ref) {
  return ref.watch(walletRepositoryProvider).fetch();
});
