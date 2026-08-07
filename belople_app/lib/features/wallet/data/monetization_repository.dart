import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

class MonetizationStatus {
  const MonetizationStatus({
    required this.followers,
    required this.likes,
    required this.videos,
    required this.views,
    required this.eligible,
    required this.monetized,
    this.applicationStatus,
  });

  final int followers;
  final int likes;
  final int videos;
  final int views;
  final bool eligible;
  final bool monetized;
  final String? applicationStatus;

  factory MonetizationStatus.fromJson(Map<String, dynamic> json) => MonetizationStatus(
        followers: (json['followers'] as num?)?.toInt() ?? 0,
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        videos: (json['videos'] as num?)?.toInt() ?? 0,
        views: (json['views'] as num?)?.toInt() ?? 0,
        eligible: json['eligible'] as bool? ?? false,
        monetized: json['monetized'] as bool? ?? false,
        applicationStatus: (json['application'] as Map<String, dynamic>?)?['status'] as String?,
      );
}

class EarningsMonth {
  const EarningsMonth({required this.month, required this.amountCents, required this.paid});
  final String month;
  final int amountCents;
  final bool paid;

  factory EarningsMonth.fromJson(Map<String, dynamic> json) => EarningsMonth(
        month: json['month'] as String? ?? '',
        amountCents: (json['amountCents'] as num?)?.toInt() ?? 0,
        paid: json['paid'] as bool? ?? false,
      );
}

/// `GET /api/monetization/status|earnings`, `POST /api/monetization/apply`
/// — see src/index.js. Requires 10k followers/likes + 5 videos.
class MonetizationRepository {
  MonetizationRepository(this._dio);
  final Dio _dio;

  Future<MonetizationStatus> status() async {
    final res = await _dio.get('/monetization/status');
    return MonetizationStatus.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<EarningsMonth>> earnings() async {
    final res = await _dio.get('/monetization/earnings');
    final months = (res.data as Map<String, dynamic>)['months'] as List<dynamic>? ?? [];
    return months.map((m) => EarningsMonth.fromJson(m as Map<String, dynamic>)).toList();
  }

  Future<void> apply({required String payoutMethod, required Map<String, dynamic> payoutDetails}) {
    return _dio.post('/monetization/apply', data: {
      'payoutMethod': payoutMethod,
      'payoutDetails': payoutDetails,
    });
  }
}

final monetizationRepositoryProvider = Provider<MonetizationRepository>((ref) {
  return MonetizationRepository(ref.watch(dioProvider));
});

final monetizationStatusProvider = FutureProvider.autoDispose((ref) {
  return ref.watch(monetizationRepositoryProvider).status();
});
