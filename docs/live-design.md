# Belople Live — the screen, as specified

Read from the user's own phone on 2026-08-13, over USB, while they held TikTok
Live open and said "follow this". Screenshots are in
`Downloads\Belople-Android\live-design\` — they are the source, not this file,
and this file exists because the phone left with them.

This describes the **viewer's** screen. Nothing here is TikTok's brand or
copy; it is the arrangement the user pointed at.

## Layout — one host

The video fills the screen. When the source is not 9:16 it is letterboxed on
black rather than cropped (seen on a screen-share stream) — so the player must
letterbox, not `BoxFit.cover`.

Everything else floats over it.

**Top-left — one dark translucent pill:**
creator avatar (circle) · display name (truncates) · ❤ + like count (`66.5K`)
· **+ Follow** in the accent colour. Follow disappears once you follow.

**Top-right, same line:**
two or three overlapping small viewer avatars · **viewer count** in its own
dark pill · a `⌄` chevron · `✕` to leave.

**Second row:** a status pill on the left and another on the right. TikTok puts
its own ranking there ("League D2 top 10%", "Popular LIVE", "Gaming Ranking")
and a goal/gallery counter on the right. Belople has no leagues — the left
slot is where the **LIVE** badge and title belong, and the right slot is free.

**Lower third — the comment stream.** Rises from the bottom, semi-transparent,
no background panel: small avatar · username in grey · comment in white.
Interleaved with system lines in the same stream:

- 👋 `NEHLOT SINGERS joined`
- ♡ `mam Alvin liked the LIVE`

Older lines fade as they rise. Nothing is scrollable back.

**Bottom bar:** rounded `Type…` field · emoji button · co-host (two-people)
icon · shop icon · **gift box** · **share** with a count.

Belople's version of that row: `Type…`, emoji, request-to-join, gift, share.
No shop.

## Layout — guests brought up ("bazamuye abantu")

The user asked specifically to be shown this one.

The video area turns **black** and becomes a **2×2 grid** of tiles, top-aligned
— not centred, not filling the screen. Below the grid is empty black down to
the comment stream.

- **Host tile**: `Host` label top-left, name pill bottom-left.
- **Guest tiles**: rank badge top-left (`1`, `2`), name pill bottom-left with a
  small **⊕** to follow that guest without leaving.
- **A cyan border marks the tile that is talking.** Two of the four carried it
  at once, so it is per-tile and live, not a single "active speaker".
- A tile with no camera shows the person's avatar centred on black.

Top bar, comment stream and bottom bar are unchanged. The viewer count keeps
its own pill; a seat icon appears beside the avatars when guests are up.

## The seat room, and joining it

Shown on 2026-08-13 when the owner was asked to demonstrate "join"
(`06-seat-grid-request.png`, `07-seat-grid-two-empty.png`). This is what they
mean by Live with people brought up, and it is more specific than the 2x2:

It is a **ten-seat room** — two large tiles on the top row, eight small ones
below in two rows of four — laid out on black and top-aligned.

- The host holds the first large tile. The second large one is whoever is
  currently featured.
- Every other seat holds one guest: their live camera if it is on, otherwise
  their avatar as a circle on dark grey.
- Each tile carries a name pill bottom-left.
- **A cyan border marks whoever is talking**, and it moves between tiles live.
- **An empty seat reads `+ Request`.** That is the whole join affordance: a
  viewer taps an empty seat to ask the host for it. Seats filled and emptied
  between two screenshots a minute apart, so the grid is live, not a snapshot.

## What this means for the build

- Phase 1 only needs the **one-host** layout. The seat room is Phase 3 and the
  spec says to leave it there.
- **The seat room cannot be built on Mux at all**, and that is worth stating
  plainly rather than discovering later. Mux takes one RTMP input and returns
  one output; ten simultaneous cameras arranged in a grid, each viewer seeing
  all of them, is not a thing it does. It needs a WebRTC/SFU provider (Agora,
  LiveKit, Daily and so on), where every participant both publishes and
  subscribes.

  This does not undo the Mux decision. One host to many viewers — Phase 1 — is
  exactly what Mux is good at and what it is cheap at, and an SFU is the wrong
  shape and much more expensive for a broadcast nobody speaks back on. The
  honest position is that Belople Live is two different products sharing a
  screen, and the second one needs its own decision and its own pricing
  conversation. The spec's §11 already says to design co-host as a separate
  layer; this is why.
- Nothing in either layout is scrollable back in time, which matches the
  no-DVR requirement: comments rise and are gone, and the video has no
  timeline. Use the live stream's own playback ID, never the asset's.
