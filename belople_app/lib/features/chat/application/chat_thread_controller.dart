import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/chat_repository.dart';
import '../data/message_model.dart';

/// Polls the thread every ~4s, matching the web app's cadence (see the
/// plan's explicit "no WebSocket" decision) — paused while the app is
/// backgrounded to save battery/data, a small addition beyond naive
/// always-on polling since it's purely client-side.
class ChatThreadController extends FamilyAsyncNotifier<ThreadData, String>
    with WidgetsBindingObserver {
  Timer? _timer;
  late String _who;

  @override
  Future<ThreadData> build(String arg) async {
    _who = arg;
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _timer?.cancel();
      WidgetsBinding.instance.removeObserver(this);
    });
    _startPolling();
    final cached = ref.read(chatRepositoryProvider).readCachedThread(_who);
    if (cached != null) {
      // Paint the last-known thread instantly; the ~4s poll (already
      // started above) replaces it with live data moments later.
      return cached;
    }
    return ref.read(chatRepositoryProvider).fetchThread(_who);
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _poll();
    } else {
      _timer?.cancel();
    }
  }

  Future<void> _poll() async {
    try {
      final data = await ref.read(chatRepositoryProvider).fetchThread(_who);
      state = AsyncData(data);
    } catch (_) {
      // Keep showing the last good state on a transient poll failure.
    }
  }

  Future<void> send(String body, {String? replyToId}) async {
    final current = state.valueOrNull;
    if (current == null || body.trim().isEmpty) return;
    // Optimistic local echo — reconciled by the next poll tick.
    final optimistic = MessageModel(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      outgoing: true,
      body: body,
      createdAt: DateTime.now(),
    );
    state = AsyncData(_copyWithMessages(current, [...current.messages, optimistic]));
    try {
      await ref.read(chatRepositoryProvider).sendMessage(
            recipientId: current.withUser.id,
            body: body,
            replyToId: replyToId,
          );
      await _poll();
    } catch (_) {
      await _poll();
    }
  }

  Future<void> deleteMessage(String messageId, {required String scope}) async {
    try {
      await ref.read(chatRepositoryProvider).deleteMessage(messageId, scope: scope);
      await _poll();
    } catch (_) {
      await _poll();
    }
  }

  ThreadData _copyWithMessages(ThreadData current, List<MessageModel> messages) {
    return ThreadData(
      withUser: current.withUser,
      messages: messages,
      requestStatus: current.requestStatus,
      requestedByMe: current.requestedByMe,
      blocked: current.blocked,
      blockedByThem: current.blockedByThem,
      isTyping: current.isTyping,
      online: current.online,
    );
  }

  /// Fire-and-forget typing ping (the UI throttles how often this is called).
  void notifyTyping() {
    ref.read(chatRepositoryProvider).sendTyping(_who).ignore();
  }

  Future<void> react(String messageId, String emoji) async {
    try {
      await ref.read(chatRepositoryProvider).reactToMessage(messageId: messageId, emoji: emoji);
      await _poll();
    } catch (_) {
      // Reaction is best-effort; the next poll reconciles regardless.
    }
  }

  Future<void> respond({required bool accept}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    try {
      await ref.read(chatRepositoryProvider).respondToRequest(current.withUser.id, accept: accept);
      await _poll();
    } catch (_) {}
  }

  Future<void> sendImage(File file) async {
    final current = state.valueOrNull;
    if (current == null) return;
    try {
      await ref.read(chatRepositoryProvider).sendMedia(
            recipientId: current.withUser.id,
            file: file,
            kind: 'image',
          );
      await _poll();
    } catch (_) {
      await _poll();
    }
  }

  Future<void> sendVoice(File file, double durationSeconds) async {
    final current = state.valueOrNull;
    if (current == null) return;
    try {
      await ref.read(chatRepositoryProvider).sendMedia(
            recipientId: current.withUser.id,
            file: file,
            kind: 'audio',
            duration: durationSeconds,
          );
      await _poll();
    } catch (_) {
      await _poll();
    }
  }
}

final chatThreadControllerProvider =
    AsyncNotifierProvider.family<ChatThreadController, ThreadData, String>(
        ChatThreadController.new);
