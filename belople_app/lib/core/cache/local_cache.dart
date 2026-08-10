import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

/// WhatsApp-style instant-render cache: raw JSON responses (the same shape
/// Dio hands back, pre-model-parsing) are written to disk on every
/// successful fetch and read back synchronously on the next cold start, so
/// a screen can paint real content on the very first frame instead of a
/// spinner — the network refresh then happens silently underneath and
/// replaces it once it lands. Not a TTL/expiry cache: stale-but-present
/// beats blank-until-loaded for a feed/profile/inbox.
class LocalCache {
  LocalCache._();

  static late Box<String> _box;

  static Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<String>('belople_cache');
  }

  static Map<String, dynamic>? getMap(String key) {
    final raw = _box.get(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> putJson(String key, Object value) {
    return _box.put(key, jsonEncode(value));
  }

  static Future<void> remove(String key) => _box.delete(key);

  /// Reads a JSON array back as a list of strings (e.g. recent searches).
  static List<String> getStringList(String key) {
    final raw = _box.get(key);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }
}
