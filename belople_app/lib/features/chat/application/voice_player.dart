import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

/// One shared audio player for every voice note in a thread — mirrors the web
/// app's single reused `<audio>` element. Because there's only ever one
/// player, starting a second voice note automatically stops the first; each
/// bubble just asks "am I the active one?" to decide how to render.
class VoicePlayer extends Notifier<String?> {
  final AudioPlayer player = AudioPlayer();

  @override
  String? build() {
    ref.onDispose(player.dispose);
    // When a note finishes, drop the active id so its bubble resets to "play".
    player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        player.pause();
        player.seek(Duration.zero);
        state = null;
      }
    });
    return null; // id of the currently-loaded voice note, or null.
  }

  /// Tapping the active note toggles play/pause; tapping a different one loads
  /// and plays it (which stops whatever was playing).
  Future<void> toggle(String id, String url) async {
    if (state == id) {
      player.playing ? await player.pause() : await player.play();
      return;
    }
    state = id;
    try {
      // LockCachingAudioSource downloads the note to the app cache on first
      // play, so replays work with no network — the audio side of offline
      // chat. Falls back to a plain URL if the cache source ever fails.
      try {
        await player.setAudioSource(LockCachingAudioSource(Uri.parse(url)));
      } catch (_) {
        await player.setUrl(url);
      }
      await player.play();
    } catch (_) {
      state = null;
    }
  }

  Future<void> seek(Duration position) => player.seek(position);
}

final voicePlayerProvider = NotifierProvider<VoicePlayer, String?>(VoicePlayer.new);
