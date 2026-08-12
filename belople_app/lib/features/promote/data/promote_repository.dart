import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

/// One purchasable reach level for a self-serve ad. Pricing is fixed:
/// 1k → $2, 10k → $20, 200k → $200 (see the product spec).
class AdTier {
  const AdTier({required this.reach, required this.priceUsd});
  final int reach;
  final int priceUsd;

  int get priceCents => priceUsd * 100;
  String get reachLabel => reach >= 1000 ? '${reach ~/ 1000}K' : '$reach';
}

const kAdTiers = <AdTier>[
  AdTier(reach: 1000, priceUsd: 2),
  AdTier(reach: 10000, priceUsd: 20),
  AdTier(reach: 200000, priceUsd: 200),
];

/// `POST /api/ads` (self-serve ad create), `POST /api/ads/:id/pay` (checkout).
/// The ad lands as `pending` + unpaid; paying then admin approval flips it to
/// `active`. See src/index.js (backend endpoints to be added/deployed).
class PromoteRepository {
  PromoteRepository(this._dio);
  final Dio _dio;

  /// Creates a pending ad. [kind] is 'video' | 'image' | 'link'. Returns the
  /// new ad id so the caller can move on to payment.
  Future<String> createAd({
    required String kind,
    required int reach,
    required int priceCents,
    File? media,
    String? linkUrl,
    String caption = '',
    String ctaText = 'Learn more',
    String? sponsorName,
    /// One country name, or null for everywhere. An ad's targeting is a real
    /// constraint, not a preference — the advertiser paid to reach a place.
    String? country,
  }) async {
    final form = FormData.fromMap({
      'kind': kind,
      'reach': '$reach',
      'priceCents': '$priceCents',
      'caption': caption,
      'ctaText': ctaText,
      if (linkUrl != null && linkUrl.isNotEmpty) 'linkUrl': linkUrl,
      if (sponsorName != null && sponsorName.isNotEmpty) 'sponsorName': sponsorName,
      if (country != null) 'countries': jsonEncode([country]),
      if (media != null)
        'media': await MultipartFile.fromFile(media.path,
            filename: kind == 'video' ? 'ad.mp4' : 'ad.jpg'),
    });
    final res = await _dio.post('/ads', data: form);
    final data = res.data as Map<String, dynamic>;
    return (data['ad'] as Map<String, dynamic>?)?['id']?.toString() ?? '';
  }

  /// Payment is stubbed until the real provider (card/MoMo/…) is wired in.
  /// For now this hits the checkout endpoint, which marks the ad paid so it
  /// enters the admin approval queue.
  Future<void> pay(String adId) => _dio.post('/ads/$adId/pay');

  /// `GET /api/ads/mine` — the caller's own ads with live stats.
  Future<List<AdStat>> myAds() async {
    final res = await _dio.get('/ads/mine');
    return ((res.data as Map<String, dynamic>)['ads'] as List<dynamic>? ?? [])
        .map((a) => AdStat.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  /// `GET /api/admin/ads/pending` — ads awaiting admin review (staff only).
  Future<List<AdStat>> pendingAds() async {
    final res = await _dio.get('/admin/ads/pending');
    return ((res.data as Map<String, dynamic>)['ads'] as List<dynamic>? ?? [])
        .map((a) => AdStat.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  /// `POST /api/admin/ads/:id/approve|reject` — staff decision.
  Future<void> decideAd(String adId, {required bool approve}) =>
      _dio.post('/admin/ads/$adId/${approve ? 'approve' : 'reject'}');
}

/// A self-serve ad plus its live stats, for the "My ads" and admin screens.
class AdStat {
  const AdStat({
    required this.id,
    required this.status,
    this.adType,
    this.mediaUrl,
    this.caption = '',
    this.linkUrl,
    this.reach,
    this.impressions = 0,
    this.clicks = 0,
    this.likes = 0,
    this.priceCents = 0,
    this.ownerUsername,
  });

  final String id;
  final String status; // pending | active | complete | rejected
  final String? adType; // video | image | link
  final String? mediaUrl;
  final String caption;
  final String? linkUrl;
  final int? reach;
  final int impressions;
  final int clicks;
  final int likes;
  final int priceCents;
  final String? ownerUsername;

  int get priceUsd => priceCents ~/ 100;
  double get progress => (reach == null || reach == 0) ? 0 : (impressions / reach!).clamp(0, 1);

  factory AdStat.fromJson(Map<String, dynamic> json) => AdStat(
        id: json['id'].toString(),
        status: json['status'] as String? ?? 'pending',
        adType: json['adType'] as String?,
        mediaUrl: json['mediaUrl'] as String?,
        caption: json['caption'] as String? ?? '',
        linkUrl: json['linkUrl'] as String?,
        reach: (json['reach'] as num?)?.toInt(),
        impressions: (json['impressions'] as num?)?.toInt() ?? 0,
        clicks: (json['clicks'] as num?)?.toInt() ?? 0,
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        priceCents: (json['priceCents'] as num?)?.toInt() ?? 0,
        ownerUsername: (json['user'] as Map<String, dynamic>?)?['username'] as String? ??
            json['ownerUsername'] as String?,
      );
}

final myAdsProvider = FutureProvider.autoDispose<List<AdStat>>((ref) {
  return ref.watch(promoteRepositoryProvider).myAds();
});

final pendingAdsProvider = FutureProvider.autoDispose<List<AdStat>>((ref) {
  return ref.watch(promoteRepositoryProvider).pendingAds();
});

final promoteRepositoryProvider = Provider<PromoteRepository>((ref) {
  return PromoteRepository(ref.watch(dioProvider));
});
