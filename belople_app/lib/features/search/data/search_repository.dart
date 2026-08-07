import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/user_model.dart';

class SearchResults {
  const SearchResults({this.accounts = const []});
  final List<UserModel> accounts;
}

/// `GET /api/search?q=` — see src/index.js.
class SearchRepository {
  SearchRepository(this._dio);
  final Dio _dio;

  Future<SearchResults> search(String query) async {
    if (query.trim().isEmpty) return const SearchResults();
    final res = await _dio.get('/search', queryParameters: {'q': query});
    final data = res.data as Map<String, dynamic>;
    final accounts = (data['accounts'] as List<dynamic>? ?? [])
        .map((a) => UserModel.fromJson(a as Map<String, dynamic>))
        .toList();
    return SearchResults(accounts: accounts);
  }
}

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(ref.watch(dioProvider));
});
