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

## What this means for the build

- Phase 1 only needs the **one-host** layout. The grid is Phase 3 and the spec
  says to leave it there.
- The grid is **not** something Mux gives us — Mux is one RTMP input, one
  output. Multiple live cameras in one frame is a different technology
  (WebRTC/SFU) or Mux-side composition. Whatever we do for co-host, this
  layout is the target, and it is the reason the spec says to design co-host
  as a separate layer.
- Nothing in either layout is scrollable back in time, which matches the
  no-DVR requirement: comments rise and are gone, and the video has no
  timeline. Use the live stream's own playback ID, never the asset's.
