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
    this.withdrawableCoins = 0,
  });

  final int coins;
  final int giftBalanceCents;
  final int lifetimeGiftsCents;
  final int giftsReceived;
  final int giftsSent;

  /// Smallest cash-out the server will accept, in cents (1 coin = 1 cent).
  final int minPayoutCents;

  /// How many coins can actually leave as money: what you have been GIFTED,
  /// less anything already taken out. Coins you bought are spendable on gifts
  /// like any other — they just can't be turned back into cash, which is the
  /// line that keeps this a gift economy rather than a money service.
  final int withdrawableCoins;

  factory WalletData.fromJson(Map<String, dynamic> json) => WalletData(
        coins: (json['coins'] as num?)?.toInt() ?? 0,
        giftBalanceCents: (json['giftBalanceCents'] as num?)?.toInt() ?? 0,
        lifetimeGiftsCents: (json['lifetimeGiftsCents'] as num?)?.toInt() ?? 0,
        giftsReceived: (json['giftsReceived'] as num?)?.toInt() ?? 0,
        giftsSent: (json['giftsSent'] as num?)?.toInt() ?? 0,
        minPayoutCents: (json['minPayoutCents'] as num?)?.toInt() ?? 1000,
        withdrawableCoins: (json['withdrawableCoins'] as num?)?.toInt() ?? 0,
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

// The coin packs and their prices are deliberately no longer defined here.
// They live in src/index.js (COIN_PACKS) and are shown on the website, which is
// where coins are bought — Google Play requires an Android app's digital-goods
// purchases to go through Play Billing and forbids naming any other route to
// pay, prices included. Nothing in the app should be able to render a price at
// all. Git has the list for when Play Billing goes in.

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

  // There is no buyCoins() here either. POST /api/coins/buy still exists and
  // the website calls it — but leaving a binding in the app is how a buy button
  // gets wired back by accident, and one accident is an account termination
  // rather than a bug. When Play Billing goes in it won't be this call anyway:
  // Play verifies the purchase itself and the server credits from that receipt.
}

final walletRepositoryProvider = Provider<WalletRepository>((ref) {
  return WalletRepository(ref.watch(dioProvider));
});

final walletProvider = FutureProvider.autoDispose((ref) {
  return ref.watch(walletRepositoryProvider).fetch();
});
