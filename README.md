# Video app

Real backend on Cloudflare: D1 for data, R2 for video files, Workers for the API.

## Already done for you

- D1 database `video-app-db` created (id `bd2c9e85-462a-42c7-839e-1850b6065625`)
- 8 tables + 9 indexes created and query-tested against the live database
- `wrangler.toml` already points at the real database id

## What you need to do

### 1. Enable R2 (only you can do this)

Go to the Cloudflare dashboard → **R2** → **Enable R2**. It asks for a payment
method, but the free tier covers 10 GB storage and 1M reads/month.

Then create the bucket:

```bash
npx wrangler r2 bucket create video-app-media
```

### 2. Deploy

```bash
npm install -g wrangler   # if you don't have it
wrangler login
wrangler deploy
```

That prints your live URL, e.g. `https://video-app.<your-subdomain>.workers.dev`.

### 3. Try it

Open the URL, sign up, upload a video. Everything from that point is real —
the video goes to R2, the account, likes, comments, shares, and reposts go to D1.

## Local development

```bash
wrangler dev
```

Uses a local D1 copy. To run against the real database instead: `wrangler dev --remote`.

## Layout

```
wrangler.toml       bindings: DB (D1), MEDIA (R2)
src/index.js        the whole API
public/index.html   the whole frontend
```

## API

| Method | Path | Notes |
|---|---|---|
| POST | `/api/auth/signup` | returns session token |
| POST | `/api/auth/login` | |
| POST | `/api/auth/logout` | |
| GET | `/api/auth/me` | validates stored token |
| GET | `/api/feed?tab=foryou\|following&cursor=` | real counts, cursor paging |
| POST | `/api/videos` | multipart: video, thumbnail, caption, width, height, duration |
| GET | `/api/videos/:id` | |
| DELETE | `/api/videos/:id` | owner only; removes R2 object too |
| POST | `/api/videos/:id/view` | |
| POST/DELETE | `/api/videos/:id/like` | returns fresh count |
| GET/POST | `/api/videos/:id/comments` | GET returns threaded replies + reaction counts |
| POST | `/api/comments/:id/react` | `{kind:"like"\|"dislike"}`; re-tapping clears it |
| DELETE | `/api/comments/:id` | author only; removes replies + reactions |
| POST | `/api/videos/:id/share` | returns share url |
| POST | `/api/videos/:id/repost` | reuses the same R2 object, no copy |
| POST/DELETE | `/api/users/:id/follow` | |
| GET | `/api/friends/requests` | |
| GET | `/api/friends/suggested` | |
| GET | `/api/users/:username` | profile + stats + videos |
| GET | `/api/search?q=` | accounts + videos |
| GET/POST | `/api/messages` | |
| GET | `/api/media/:key` | streams from R2, supports Range |
| GET | `/api/settings` | full settings for the signed-in user |
| PATCH | `/api/settings` | username, display name, bio, email, privacy, notifications |
| GET | `/api/settings/username-available?username=` | live check while typing |
| POST | `/api/settings/avatar` | multipart `avatar`; replaces old file in R2 |
| DELETE | `/api/settings/avatar` | |
| POST | `/api/settings/password` | verifies current password, revokes other sessions |
| DELETE | `/api/settings/sessions` | sign out other devices |
| DELETE | `/api/settings/account` | password-confirmed; wipes D1 rows + R2 files |

## Motion

Movement is handled as one small system rather than per-screen tweaks, so the
whole app feels consistent:

- **Every button springs when pressed** — a single global `button:active` rule
  scales it to 0.9 with a slight overshoot on release, so the bounce is felt
  everywhere without touching individual buttons.
- **Pages ease in** from 12px below and faded, a settle rather than a slide.
- **Sheets** rise on a decelerating curve and dim the screen behind them; both
  the X and a tap on the backdrop close them through the same slide-down, so a
  sheet never just vanishes.
- **The active nav icon** lifts and grows a touch when its tab is selected.
- **Toasts** fade and drift down as they leave instead of blinking out.

Everything runs between 0.18 and 0.32 seconds — fast enough to stay responsive,
slow enough to read as motion. All of it collapses to near-instant under
`prefers-reduced-motion`, so anyone who's asked their device for less animation
gets a still interface instead.

## Navigation and profiles

The bottom nav marks the active tab with a **short bar sliding underneath**,
the way the phone's Timer app does. It reads as "you are here" more clearly than
a filled pill, and both tabs stay identical apart from the marker.

**Other people's profiles** open by tapping a username on a video, a search
result, or a message thread. They show **Follow** and **Message** where your own
profile shows Edit profile. Your own profile is the only one with the wallet
chip.

Tapping your own avatar clears `viewUser` first — without that, it would show
whoever you last looked at, which is the kind of bug that only appears after
you've browsed someone else and come back.

**Messaging respects the recipient's privacy setting.** `allow_messages` is
enforced server-side on send: `nobody` blocks everyone, `followers` requires
that *they* follow *you* (not the reverse). Verified against the live database in
both directions — a follower was allowed through, a stranger was refused. Without
this the setting in the settings screen would be decoration.

## Wallet

The profile's top corner has a **coin button with no number** — the balance
lives inside, not on the chrome. Opening it shows the gift balance,
monetization progress, coins, and history in one place, since they're all the
same subject.

Monetization progress moved off the profile grid and into the wallet for the
same reason: money in one screen, videos in the other.

## Gifts and coins

Two currencies, deliberately kept apart:

- **Coins** — what a viewer buys and spends. They only go one way: in.
- **Cents** — what a creator receives and can withdraw.

They're separate so nobody can buy coins, gift themselves, and cash the same
money back out in a loop.

A viewer taps the gift button on a video, picks from eight gifts (Rose → Trophy),
and the creator keeps **50%** of its value. The gift chip sits at the top of the
profile showing the coin balance; the wallet page shows the gift balance, which
is the withdrawable side.

### Money can't be conjured or lost

The balance check lives in the SQL, not in JavaScript:

```sql
UPDATE users SET coin_balance = coin_balance - ?
 WHERE id = ? AND coin_balance >= ?
```

If the row doesn't change, the sender didn't have the coins and no gift is
written. Two simultaneous requests can't both pass, because the database — not
the app — decides. Verified on the live database: sending 500 coins with a
balance of 100 returned `changes: 0`, and a valid 50-coin gift moved the balance
100 → 50 while crediting the creator exactly 25¢.

Every balance change is also written to `wallet_tx` with the resulting balance,
so the ledger can always be reconciled against the wallets. Audited after a test
gift: 100 coins gifted = 100¢ gross → 50¢ creator + 50¢ platform, and the sum of
all wallet balances matched the sum of all gifts. Nothing invented, nothing lost.

### The rose that paid nothing

The first gift table started at 1 coin. At a 50% share that's
`floor(1 × 0.5) = 0` — **the viewer paid a cent and the creator earned nothing**,
with the platform quietly keeping all of it. The arithmetic balanced, so no test
of "is money conserved" would have caught it; it only showed up printing the
actual split per gift.

Every gift now starts at 2 coins, so the smallest one still pays the creator.

### What this does NOT do

**No card processor is wired up.** Buying coins files a request; the viewer pays
by Mobile Money and an admin adds the coins from the Coins tab once the money
actually lands. Approval flips the row `WHERE status='pending'` and only credits
if that update changed something — two admins clicking at once can't credit the
same purchase twice.

Withdrawals are the same story as monetization payouts: the balance is tracked
honestly, but moving real money out needs a payment provider and a registered
business.

## Monetization

Creators apply once they clear three thresholds (set in `MONETIZE_RULES`):
**10,000 followers, 10,000 likes, 5 videos.** The monetization screen shows live
progress bars against each, and the apply button only appears once all three are
green.

Reposts don't count toward the video requirement — `WHERE repost_of IS NULL`.
Reposting someone else's work isn't creating five videos.

**Eligibility is checked twice, from the database, never from the client:** once
when applying, and again when an admin approves. That second check matters — an
application row stores the numbers *at the time of applying*, and those can be
inflated or simply go stale. Tested against the live database: a row claiming
10,500 followers whose real count had dropped to 0 was correctly refused at
approval.

Earnings are `views / 1000 × CENTS_PER_1K_VIEWS` (currently $0.02/1k, so 1M
views ≈ $20). Amounts round down to whole cents, and anything under
`MIN_PAYOUT_CENTS` ($10) stays held rather than queued.

### What this does NOT do

**It does not send money.** Real payouts need Stripe Connect, Mobile Money
(MTN/Airtel), or a bank integration, and a registered business behind them. What
exists here is the accounting: earnings are calculated from real view counts,
payout details are collected, and the admin sees a queue with each creator's
method and amount. "Mark paid" records that *you* sent the money — it doesn't
move it. Wiring up an actual payment provider is a separate job.

## Admin

Three roles: `user`, `moderator`, `admin`.

| | moderator | admin |
|---|---|---|
| View stats, users, reports | ✓ | ✓ |
| Ban / unban, resolve reports | ✓ | ✓ |
| Approve monetization | ✓ | ✓ |
| Change roles | | ✓ |
| Run earnings, mark paid | | ✓ |
| Read the audit log | | ✓ |

**Getting the first admin.** `POST /api/admin/bootstrap` promotes the logged-in
account, but only while the site has zero admins — after that it returns 409
forever. Verified against the live database: with one admin present, a second
account is refused. The button is in Settings and disappears once you have a
role.

**Bans bite immediately.** Banning deletes the user's sessions, blocks them at
login, and rejects their existing token at `getUser`. Their videos also drop out
of the feed, search, and suggestions — a ban that leaves the content playing
isn't a ban. That gap was real: `FEED_SQL` joined `users` without ever checking
`status`, so a banned account's videos would have kept playing for everyone.

**A moderator cannot ban an admin.** Otherwise the person you appointed could
remove you.

**Every admin action is logged** — who, what, when, and the note they gave.
Without it you can't answer "who banned this account and why" three months later.

## Speed

Scrolling and playback were tuned in four places, because a slow feed is never
one problem:

**Videos load before you reach them.** The current slide plus two ahead and one
behind are preloaded (`preload="auto"` + `load()`); everything else drops its
buffer and keeps only its poster. Preloading all 15 is worse than preloading
none — the browser fights itself for bandwidth and the feed stutters after a
minute. Four warm videos is the sweet spot: the next one is always ready, and
scrolling back one still plays instantly.

**Playback starts at 25% visible**, not 60%. By the time a slide is 60% on
screen you've already been staring at a still frame.

**Snapping is immediate.** `scroll-snap-stop: always` plus `scroll-behavior:
auto` — the default smooth easing is exactly the "rorante" glide that makes a
feed feel heavy. `contain: layout paint` on each slide stops the browser
recalculating the whole feed on every frame.

**Media is cached at the edge.** `caches.default` with `immutable`, filled via
`ctx.waitUntil` so the first viewer doesn't wait for the cache write. A video's
bytes never change, so the second viewer anywhere in the world gets it from a
nearby datacentre instead of R2 — faster for them, and fewer billed R2
operations for you.

**Pagination** fetches the next page while 3 videos remain (was ~1), and the
scroll listener is rAF-throttled and `passive` — the raw event fires hundreds of
times per swipe and doesn't need answering that often. Page size is 15, since
feed rows are metadata only; the video bytes stream separately.

### The index that wasn't there

The feed runs five correlated subqueries per video. `EXPLAIN QUERY PLAN` on the
live database showed the repost count doing `SCAN r` — a full table scan of
`videos`, once per video. At 15 videos and 10k uploads that's 150,000 row reads
for a single feed load, and it would have looked perfectly fine in testing with
four rows.

Adding `idx_videos_repost_of` turned it into
`SEARCH r USING COVERING INDEX`. Every subquery in the feed now resolves through
an index — verified with `EXPLAIN QUERY PLAN`, not assumed.

## Feed layout

The author line sits above the caption: avatar, username, then a solid white
**Follow** pill. Once followed it turns translucent and reads "Following".

There's one follow control, not two — the rail is just the four action buttons
(like, comment, repost, share). An avatar on the rail would repeat the one
already sitting next to the username two inches away.

The song line was removed from the feed as well: with the author row, caption,
and the nav pill all stacked in the same corner, it was one element too many.
The backend still records `song` on every video, so it can surface elsewhere
without a schema change.

Your own videos show no Follow control, since following yourself isn't a thing.
The API returns a `following` flag per video (an `EXISTS` against `follows`), so
the button renders in the right state on first paint rather than flickering
after a second request. Following an author updates every visible video by that
person, not just the current slide.

Tapping Follow doesn't pause the video: the tap handler ignores anything inside
`.author` and `.rail`.

## Search

Accounts are matched on **display name or username**, and results show the
display name in bold with the username underneath — no `@` prefix anywhere. You
can search "Africans" and find `africans_gone_wild`. Matching is
case-insensitive, so "kevin" finds "Kevin".

## Recording and posting

The `+` button opens a live camera rather than a file picker:

- **Record** with the shutter — it becomes a square while recording, with a red
  timer at the top. The mode strip (`10m` / `60s` / `15s`) sets the cap and
  recording stops itself when it's reached.
- **Flip** between front and back. The selfie view is mirrored on screen, the
  way every camera app does it.
- **Gallery** picks an existing video instead; anything over 10 minutes is
  rejected before it uploads.
- **Post screen** takes a description and a visibility choice (Everyone /
  Followers / Only me), with Retake to go back.

The upload uses `XMLHttpRequest` rather than `fetch`, because only XHR reports
progress events — the bar under the Post button is real, not a fake animation.

**Camera permissions.** If the user blocks the camera, or the device has none,
the screen explains which of the two happened and offers the gallery instead of
showing a dead black rectangle.

**Releasing the camera.** `render()` stops every live track before clearing the
DOM. Without that, `innerHTML = ""` drops the video element while the stream
stays open, and the camera light stays on after leaving the screen.

**Recording format** is negotiated: VP9 → VP8 → WebM → MP4, picking the first
the browser supports (Chrome takes VP9, Safari falls to MP4). Duration is
measured from wall-clock time, since WebM blobs from `MediaRecorder` often carry
no duration metadata.

## Visibility

Every video carries `public`, `followers`, or `private`, and the feed enforces it
in SQL on both tabs: your own videos always show, public shows to everyone,
followers-only requires an accepted follow, private never shows to anyone else.
Verified against the live database with three accounts — a stranger saw only the
public video, a follower saw public plus followers-only, and the owner saw all
three.

## Comments

The sheet is white and covers 68% of the screen, so the video keeps playing
above it — the same arrangement TikTok uses. Each row shows the display name in
grey, the comment in black, a relative timestamp ("8h", "5d"), a Reply button,
and heart/dislike buttons stacked on the right.

- **Reactions** are one per user per comment. Tapping the active one clears it;
  tapping the other switches sides rather than adding a second vote (enforced by
  a primary key on `(user_id, comment_id)` plus `ON CONFLICT ... DO UPDATE`).
  The UI updates on tap and reconciles against the server's count when it
  answers, so a failed request reverts instead of lying.
- **Replies** are one level deep. Replying to a reply attaches to the top-level
  comment, which is what keeps the thread readable.
- **No image attachments** in comments, as requested — text only.
- Comment bodies are HTML-escaped before rendering, so a comment containing
  markup is displayed, not executed. Emoji pass through untouched.

Deleting a comment uses a recursive CTE to gather every descendant and deletes
children before parents. The obvious two-step version (`DELETE WHERE parent_id`,
then `DELETE WHERE id`) passes a quick test but throws
`FOREIGN KEY constraint failed` the moment a chain runs deeper than one level —
this was caught by running it against the real database rather than assuming.

## Settings

The gear opens a real settings screen backed by the database:

- **Profile photo** — uploads to R2 at `avatars/<user>/<uuid>.jpg`, replaces the
  previous file rather than orphaning it. The photo then shows on the top-left
  button, the feed rail, comments, search, messages, and the profile page.
- **Username** — checked for availability as you type (case-insensitive), so a
  clash surfaces before you hit save rather than after.
- **Display name, bio, email** — saved together via the Save changes button.
- **Privacy** — private account, plus who can message and who can comment.
- **Notifications** — likes, comments, new followers. Toggles save immediately
  and revert if the request fails.
- **Password** — requires the current password, and signs out every other
  session on success.
- **Delete account** — password-confirmed, removes the user's videos from R2 and
  every related row from D1.

These columns (`is_private`, `allow_messages`, `allow_comments`, `notify_*`,
`language`) were added to the live `users` table already — no migration needed.

## Notes on decisions

**Video sizing.** The player reads each video's real dimensions on
`loadedmetadata`. Portrait sources (ratio < 0.62, i.e. 9:16 like TikTok) get
`object-fit: cover` so they fill the screen edge to edge. Anything wider
letterboxes against black instead of cropping faces out of frame — this is what
TikTok and YouTube Shorts do with non-portrait uploads. Caption and handle sit
in an overlay layer above the video, below the Following/For you tabs.

**Range requests.** `/api/media/*` honours HTTP Range, so seeking and mobile
buffering work. Without it, videos only play start-to-finish.

**Reposts share storage.** A repost inserts a row pointing at the original
`r2_key` rather than copying the file, so reposting costs no extra storage.

**Passwords** are PBKDF2-SHA256, 100k iterations, random 16-byte salt per user.

**Thumbnails** are generated in the browser from the first frame at upload time,
so the feed shows a poster instead of a black rectangle before playback starts.

## Costs

Free tier: D1 5GB + 5M reads/day, R2 10GB + 1M Class A ops, Workers 100k
requests/day. A small app stays free. R2 has no egress fees, which is why it
suits video.
