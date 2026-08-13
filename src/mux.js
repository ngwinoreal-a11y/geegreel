// The only file in Belople that knows Mux exists.
//
// Everything above it deals in Belople's own LiveSession; this translates. If
// the provider ever changes, this file is what gets rewritten and comments,
// likes, follows, requests, notifications and discovery are untouched — which
// is the whole reason it is separate.
//
// The secrets never leave the Worker: MUX_TOKEN_ID / MUX_TOKEN_SECRET are
// Cloudflare secrets, and nothing here is ever sent to the app. The app gets a
// stream key when it starts broadcasting and a playback id when it watches,
// and neither can be used to reach the account.

const MUX_API = "https://api.mux.com/video/v1";

function authHeader(env) {
  const id = env.MUX_TOKEN_ID;
  const secret = env.MUX_TOKEN_SECRET;
  if (!id || !secret) {
    throw new Error(
      "Mux is not configured — set MUX_TOKEN_ID and MUX_TOKEN_SECRET with `wrangler secret put`"
    );
  }
  return "Basic " + btoa(`${id}:${secret}`);
}

async function muxFetch(env, path, init = {}) {
  const res = await fetch(`${MUX_API}${path}`, {
    ...init,
    headers: {
      Authorization: authHeader(env),
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });

  // 404 on a delete is success: the thing we wanted gone is gone. Saying so
  // here is what lets cleanup run twice safely.
  if (res.status === 404) return { ok: true, notFound: true, body: null };

  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { raw: text };
  }

  if (!res.ok) {
    const detail = body?.error?.messages?.join("; ") || body?.raw || res.statusText;
    const err = new Error(`Mux ${init.method || "GET"} ${path} failed (${res.status}): ${detail}`);
    err.status = res.status;
    err.muxBody = body;
    throw err;
  }
  return { ok: true, notFound: false, body };
}

/// How long a single broadcast may run before Mux itself cuts it off. This is
/// the hard stop behind the app's own timer: if the creator's phone dies mid
/// stream, or the app is killed, or our sweeper never runs, Mux still stops
/// billing at this point. Mux's own default is 12 HOURS, which is the single
/// most expensive default in the whole integration.
export function maxLiveSeconds(env) {
  const n = parseInt(env.LIVE_MAX_SECONDS || "", 10);
  if (Number.isFinite(n) && n >= 60 && n <= 43200) return n;
  return 3600; // 60 minutes
}

/// Creates the Mux side of a session and returns the two things the rest of
/// the system needs: where the creator pushes to, and what viewers play.
///
/// The playback id returned is the LIVE STREAM's. Mux also gives the recorded
/// asset its own playback id, and that one is the DVR — hand it to a viewer
/// and they can scrub back to the beginning, which is exactly the replay
/// Belople does not have. It is never read here.
export async function createLiveStream(env, { latencyMode, reconnectWindow } = {}) {
  const mode = latencyMode || env.LIVE_LATENCY_MODE || "standard";

  // Standard latency is the default on purpose. Reduced/low latency force the
  // reconnect window to 0, meaning the first time a phone drops a bar of
  // signal the broadcast is over. On mobile networks here that trades a few
  // seconds of delay nobody notices for a stream that survives a lift.
  const reconnect = reconnectWindow ?? (mode === "standard" ? 60 : 0);

  const { body } = await muxFetch(env, "/live-streams", {
    method: "POST",
    body: JSON.stringify({
      playback_policy: ["public"],
      latency_mode: mode,
      reconnect_window: reconnect,
      max_continuous_duration: maxLiveSeconds(env),
      // Mux creates an asset for every RTMP session no matter what we put
      // here — there is no setting that turns recording off. These settings
      // only shape the asset we are about to delete, so they stay minimal.
      new_asset_settings: { playback_policy: [] },
    }),
  });

  return {
    liveStreamId: body.data.id,
    streamKey: body.data.stream_key,
    playbackId: body.data.playback_ids?.[0]?.id || null,
    ingestUrl: "rtmp://live.mux.com/app",
  };
}

/// Tells Mux the broadcast is over rather than waiting out the reconnect
/// window. Used when the creator taps End — the webhook still confirms it.
export async function completeLiveStream(env, liveStreamId) {
  if (!liveStreamId) return { ok: true, notFound: true };
  return muxFetch(env, `/live-streams/${liveStreamId}/complete`, { method: "PUT" });
}

/// Deletes the live stream itself. Belople creates one per session rather than
/// reusing them, so nothing is left behind holding a stream key.
export async function deleteLiveStream(env, liveStreamId) {
  if (!liveStreamId) return { ok: true, notFound: true };
  return muxFetch(env, `/live-streams/${liveStreamId}`, { method: "DELETE" });
}

/// Deletes the recording. This is the one that costs money if it is missed:
/// storage bills from the moment the asset exists, and Mux keeps it forever
/// otherwise. Plus/premium storage is prorated by the fraction of the month it
/// was stored, so deleting within minutes costs approximately nothing —
/// leaving it costs $0.0024 per minute of video every month, for good.
///
/// A 404 counts as done, so running cleanup twice is not an error.
export async function deleteAsset(env, assetId) {
  if (!assetId) return { ok: true, notFound: true };
  return muxFetch(env, `/assets/${assetId}`, { method: "DELETE" });
}

/// Verifies a webhook really came from Mux.
///
/// The header is `t=<unix seconds>,v1=<hex hmac>`, and the signed payload is
/// the timestamp, a dot, and the RAW body — so callers must pass the body text
/// exactly as received, before any JSON.parse.
export async function verifyWebhook(env, rawBody, signatureHeader) {
  const secret = env.MUX_WEBHOOK_SECRET;
  // Refuse rather than wave it through: an unverified webhook can end anyone's
  // live stream, and "we couldn't check" must never mean "so we trusted it".
  if (!secret) throw new Error("MUX_WEBHOOK_SECRET is not set — cannot verify the webhook");
  if (!signatureHeader) return false;

  const parts = Object.fromEntries(
    signatureHeader.split(",").map((p) => p.split("=").map((s) => s.trim()))
  );
  const timestamp = parts.t;
  const provided = parts.v1;
  if (!timestamp || !provided) return false;

  // Five minutes, to bound replay of a captured request.
  const age = Math.abs(Math.floor(Date.now() / 1000) - parseInt(timestamp, 10));
  if (!Number.isFinite(age) || age > 300) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${timestamp}.${rawBody}`)
  );
  const expected = [...new Uint8Array(mac)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  // Constant time: a fast mismatch leaks where the first wrong byte is.
  if (expected.length !== provided.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ provided.charCodeAt(i);
  return diff === 0;
}

/// The HLS URL a viewer plays. Built from the LIVE stream's playback id, so
/// the manifest is the sliding live window and there is nothing behind it to
/// seek to.
export function playbackUrl(playbackId) {
  return `https://stream.mux.com/${playbackId}.m3u8`;
}
