/// The backend (src/index.js) returns `createdAt` as a raw milliseconds-
/// since-epoch NUMBER everywhere (`Date.now()`-style), not an ISO string —
/// confirmed against the live API (`curl .../api/feed`: `"createdAt":
/// 1786044605707`). Every model's `DateTime.tryParse(json['createdAt'] as
/// String?)` was therefore throwing on every single item (`num` is not a
/// `String`), which is what took down the feed/posts/messages/notifications
/// screens with "Couldn't load ..." — the AsyncNotifier error boundary was
/// catching a real parse crash, not a network failure.
///
/// Accepts both shapes defensively (a `String` ISO date still parses fine)
/// so this doesn't silently break again if a future endpoint ever does
/// return a string.
DateTime parseTimestamp(dynamic value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String) {
    final asNumber = num.tryParse(value);
    if (asNumber != null) {
      return DateTime.fromMillisecondsSinceEpoch(asNumber.toInt());
    }
    return DateTime.tryParse(value) ?? DateTime.now();
  }
  return DateTime.now();
}
