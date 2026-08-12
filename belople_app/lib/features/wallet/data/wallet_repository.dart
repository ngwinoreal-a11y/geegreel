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
    this.minPayoutCents = 1000,
  });

  final int coins;
  final int giftBalanceCents;
  final int lifetimeGiftsCents;
  final int giftsReceived;
  final int giftsSent;

  /// Smallest cash-out the server will accept, in cents (1 coin = 1 cent).
  final int minPayoutCents;

  factory WalletData.fromJson(Map<String, dynamic> json) => WalletData(
        coins: (json['coins'] as num?)?.toInt() ?? 0,
        giftBalanceCents: (json['giftBalanceCents'] as num?)?.toInt() ?? 0,
        lifetimeGiftsCents: (json['lifetimeGiftsCents'] as num?)?.toInt() ?? 0,
        giftsReceived: (json['giftsReceived'] as num?)?.toInt() ?? 0,
        giftsSent: (json['giftsSent'] as num?)?.toInt() ?? 0,
        minPayoutCents: (json['minPayoutCents'] as num?)?.toInt() ?? 1000,
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

/// Must stay in step with COIN_PACKS in src/index.js — /api/coins/buy rejects
/// any amount that isn't a known pack, so a pack listed here and not there is
/// a button that always fails. 1 coin = 1 cent, so cents == coins throughout.
const List<CoinPack> kCoinPacks = [
  CoinPack(100, 100),       // $1
  CoinPack(500, 500),       // $5
  CoinPack(1000, 1000),     // $10
  CoinPack(2500, 2500),     // $25
  CoinPack(5000, 5000),     // $50
  CoinPack(10000, 10000),   // $100
  CoinPack(20000, 20000),   // $200
  CoinPack(50000, 50000),   // $500
];

/// `GET /api/wallet`, `GET /api/wallet/history`, `POST /api/coins/buy` — see
/// src/index.js. A coin purchase is recorded as *pending*; an admin confirms
/// the real-world payment (there's no in-app payment processor), matching the
/// web app's own flow.
class WalletRepository {
  WalletRepository(this._dio);
  final Dio _dio;

  /// Asks for a coin balance to be paid out. The server deducts the coins
  /// immediately — so the same coins can't be requested and then spent while
  /// the payout waits — and returns them if the request is turned down.
  Future<void> requestPayout({
    required int coins,
    required String method,
    required String details,
  }) =>
      _dio.post('/wallet/payout', data: {
        'coins': coins,
        'method': method,
        'details': details,
      });

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
