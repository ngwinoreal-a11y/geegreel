import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/user_model.dart';

/// `GET/PATCH /api/settings` — see src/index.js.
class SettingsRepository {
  SettingsRepository(this._dio);
  final Dio _dio;

  Future<UserModel> update(Map<String, dynamic> fields) async {
    final res = await _dio.patch('/settings', data: fields);
    final data = res.data as Map<String, dynamic>;
    return UserModel.fromJson(data['user'] as Map<String, dynamic>);
  }

  /// `POST /api/settings/avatar` (multipart, field `avatar`) — server caps at
  /// 5MB / image types, drops the old file, returns the new `avatarUrl`.
  Future<String> uploadAvatar(String filePath) async {
    final form = FormData.fromMap({
      'avatar': await MultipartFile.fromFile(filePath, filename: 'avatar.jpg'),
    });
    final res = await _dio.post('/settings/avatar', data: form);
    return (res.data as Map<String, dynamic>)['avatarUrl'] as String;
  }

  /// `DELETE /api/settings/avatar` — reverts to the initials placeholder.
  Future<void> removeAvatar() {
    return _dio.delete('/settings/avatar');
  }

  /// `POST /api/settings/password` — verifies the current password, sets the
  /// new one, and signs out every other session server-side.
  Future<void> changePassword({required String current, required String next}) {
    return _dio.post('/settings/password', data: {
      'currentPassword': current,
      'newPassword': next,
    });
  }

  /// `DELETE /api/settings/account` — password-confirmed, permanent.
  Future<void> deleteAccount(String password) {
    return _dio.delete('/settings/account', data: {'password': password});
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(dioProvider));
});
