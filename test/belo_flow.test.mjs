// Belo Flow — pure-logic tests. Run: `node --test test/belo_flow.test.mjs`
// These cover the FINAL SUCCESS CRITERIA (Scenarios A–G) without a database.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_CONFIG, mergeConfig, extractTopics, recencyPenalty, effectiveSeparation,
  scoreCandidate, classifyBucket, reRank,
} from "../src/belo_flow.js";

const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;

// A minimal scored item for reRank (the shape reRank consumes).
function item(id, creatorId, opts = {}) {
  return {
    id, creatorId,
    topics: opts.topics || [],
    base: opts.base ?? 0.5,
    signals: opts.signals || {},
    buckets: opts.buckets || ["personalized"],
    reasons: [],
    viewerLastSeenMs: opts.viewerLastSeenMs ?? null,
    viewerEngagedThis: opts.viewerEngagedThis ?? false,
  };
}

function maxConsecutiveSameCreator(feed) {
  let max = 1, cur = 1;
  for (let i = 1; i < feed.length; i++) {
    if (feed[i].creatorId === feed[i - 1].creatorId) { cur++; max = Math.max(max, cur); }
    else cur = 1;
  }
  return feed.length ? max : 0;
}

// ---------------------------------------------------------------------------
test("Scenario B: 10 videos from Creator A are NOT served consecutively", () => {
  const items = [];
  for (let i = 0; i < 10; i++) items.push(item(`a${i}`, "A", { base: 0.9 })); // A dominates on raw score
  for (const c of ["B", "C", "D", "E"]) items.push(item(`${c}0`, c, { base: 0.5 }));
  const feed = reRank(items, DEFAULT_CONFIG, { activeCreators: 5, seed: 1, limit: 12 });
  assert.ok(feed.length >= 8, "feed should fill");
  // The core invariant: A must never appear twice in a row UNTIL every other
  // creator has already been placed. Consecutive A is only allowed once the
  // catalogue offers no alternative (graceful degradation) — never before.
  let firstAAt = -1;
  for (let i = 1; i < feed.length; i++) {
    if (feed[i].creatorId === "A" && feed[i - 1].creatorId === "A") { firstAAt = i; break; }
  }
  if (firstAAt !== -1) {
    const before = new Set(feed.slice(0, firstAAt).map((x) => x.creatorId));
    for (const c of ["B", "C", "D", "E"]) {
      assert.ok(before.has(c), `A clustered at ${firstAAt} before creator ${c} was used`);
    }
  }
  // A must not monopolise the top of the feed.
  const firstFive = feed.slice(0, 5).filter((x) => x.creatorId === "A").length;
  assert.ok(firstFive <= 3, `A over-represented up front: ${firstFive}/5`);
});

test("Scenario A: after Creator A, the next pick favours another creator", () => {
  const items = [item("a1", "A", { base: 0.8 }), item("a2", "A", { base: 0.79 }), item("b1", "B", { base: 0.6 })];
  const feed = reRank(items, DEFAULT_CONFIG, { activeCreators: 2, seed: 3, limit: 3 });
  assert.equal(feed[0].creatorId, "A");
  assert.equal(feed[1].creatorId, "B", "second slot should switch creators");
});

test("Scenario D: a just-watched video is not served again immediately", () => {
  const items = [
    item("seen", "A", { base: 0.95, viewerLastSeenMs: 5000 }),   // watched 5s ago
    item("fresh", "B", { base: 0.5, viewerLastSeenMs: null }),
  ];
  const feed = reRank(items, DEFAULT_CONFIG, { activeCreators: 2, seed: 2, limit: 2 });
  assert.equal(feed[0].id, "fresh", "just-seen video must be suppressed despite higher base");
});

test("Scenario E: an engaged video becomes eligible again sooner than a skipped one", () => {
  // 3 days after viewing: the loved video's penalty should be clearly lower.
  const engaged = recencyPenalty(3 * DAY, true);
  const notEngaged = recencyPenalty(3 * DAY, false);
  assert.ok(engaged < notEngaged, "engaged decays faster");
  // 30 days out, both are essentially eligible again.
  assert.ok(recencyPenalty(30 * DAY, false) < 0.1, "old video is eligible again");
  // Just-seen is a hard block regardless of engagement.
  assert.equal(recencyPenalty(1000, true), 1);
  assert.equal(recencyPenalty(null, false), 0, "never-seen has no penalty");
});

test("Scenario C: a small/new creator's video is competitive and lands in discovery", () => {
  const smallCreatorVid = {
    uniqViewers: 0, avgCompletion: 0, rawViews: 0, likeCount: 0, commentCount: 0, shareCount: 0,
    durationSec: 30, ageMs: HOUR, creatorFollowers: 20, topics: ["comedy"], creatorId: "small",
    viewerFollowsCreator: false, viewerCreatorFamiliarity: 0, viewerLastSeenMs: null,
  };
  const bigEstablishedVid = {
    uniqViewers: 200, avgCompletion: 0.35, rawViews: 5000, likeCount: 100, commentCount: 5, shareCount: 1,
    durationSec: 30, ageMs: 10 * DAY, creatorFollowers: 100000, topics: ["comedy"], creatorId: "big",
    viewerFollowsCreator: false, viewerCreatorFamiliarity: 1, viewerLastSeenMs: null,
  };
  const profile = { topics: {} };
  const small = scoreCandidate(smallCreatorVid, profile, DEFAULT_CONFIG);
  const big = scoreCandidate(bigEstablishedVid, profile, DEFAULT_CONFIG);
  assert.ok(small.buckets.includes("discovery"), "small/new creator qualifies for discovery");
  // The unproven small creator gets a real test-audience shot: not buried.
  assert.ok(small.signals.coldStart > 0, "cold-start boost applied");
  assert.ok(small.base >= big.base * 0.8, `small creator must be competitive (small=${small.base.toFixed(3)} big=${big.base.toFixed(3)})`);
});

test("Scenario C follow-up: a small creator with STRONG response can outrank a big one with weak response", () => {
  const profile = { topics: {} };
  const smallStrong = scoreCandidate({
    uniqViewers: 30, avgCompletion: 0.85, avgWatchMs: 26000, rawViews: 40, likeCount: 20, shareCount: 8,
    durationSec: 30, ageMs: 6 * HOUR, creatorFollowers: 20, topics: ["music"], creatorId: "s",
    viewerCreatorFamiliarity: 0,
  }, profile, DEFAULT_CONFIG);
  const bigWeak = scoreCandidate({
    uniqViewers: 500, avgCompletion: 0.15, avgWatchMs: 4000, rawViews: 100000, likeCount: 50, shareCount: 0,
    durationSec: 30, ageMs: 20 * DAY, creatorFollowers: 1000000, topics: ["music"], creatorId: "b",
    viewerCreatorFamiliarity: 1,
  }, profile, DEFAULT_CONFIG);
  assert.ok(smallStrong.base > bigWeak.base, `real response must beat follower count (${smallStrong.base.toFixed(3)} vs ${bigWeak.base.toFixed(3)})`);
});

test("Scenario F: small data (2 creators) still produces a full, non-empty feed", () => {
  assert.equal(effectiveSeparation(3, 2), 1, "separation relaxes for 2 creators");
  assert.equal(effectiveSeparation(3, 1), 0, "single creator: no separation demanded");
  const items = [];
  for (let i = 0; i < 6; i++) items.push(item(`a${i}`, "A", { base: 0.6 }));
  for (let i = 0; i < 6; i++) items.push(item(`b${i}`, "B", { base: 0.6 }));
  const feed = reRank(items, DEFAULT_CONFIG, { activeCreators: 2, seed: 9, limit: 10 });
  assert.equal(feed.length, 10, "feed fills even with only 2 creators");
  assert.ok(maxConsecutiveSameCreator(feed) <= 1, "still alternates the two creators");
});

test("Single creator: feed does not error and returns everything available", () => {
  const items = [item("a1", "A"), item("a2", "A"), item("a3", "A")];
  const feed = reRank(items, DEFAULT_CONFIG, { activeCreators: 1, seed: 1, limit: 5 });
  assert.equal(feed.length, 3, "returns all it has, gracefully");
});

test("Composition: buckets are honoured approximately over a full session", () => {
  const items = [];
  // 30 personalized, 30 discovery, 20 trending, 20 exploration candidates.
  for (let i = 0; i < 30; i++) items.push(item(`p${i}`, `cp${i}`, { base: 0.7, buckets: ["personalized"] }));
  for (let i = 0; i < 30; i++) items.push(item(`d${i}`, `cd${i}`, { base: 0.5, buckets: ["discovery"] }));
  for (let i = 0; i < 20; i++) items.push(item(`t${i}`, `ct${i}`, { base: 0.6, buckets: ["trending"] }));
  for (let i = 0; i < 20; i++) items.push(item(`e${i}`, `ce${i}`, { base: 0.4, buckets: ["exploration"] }));
  const feed = reRank(items, DEFAULT_CONFIG, { activeCreators: 100, seed: 5, limit: 20 });
  const counts = { personalized: 0, discovery: 0, trending: 0, exploration: 0 };
  for (const f of feed) counts[f.slotBucket]++;
  // Personalized should be the plurality (~60%), discovery meaningfully present.
  assert.ok(counts.personalized >= 9, `personalized share too low: ${counts.personalized}/20`);
  assert.ok(counts.discovery >= 2, `discovery share too low: ${counts.discovery}/20`);
  assert.ok(counts.exploration >= 1, "exploration present (anti-bubble)");
});

test("Freshness: the feed varies with the session seed (fresh each open)", () => {
  const items = [];
  for (let i = 0; i < 20; i++) items.push(item(`v${i}`, `c${i % 6}`, { base: 0.5 + (i % 5) * 0.02 }));
  const a = reRank(items, DEFAULT_CONFIG, { activeCreators: 6, seed: 111, limit: 12 }).map((x) => x.id).join(",");
  const b = reRank(items, DEFAULT_CONFIG, { activeCreators: 6, seed: 999, limit: 12 }).map((x) => x.id).join(",");
  assert.notEqual(a, b, "different session seeds should reorder the feed");
  // ...but the SAME seed is reproducible (needed for stable pagination).
  const a2 = reRank(items, DEFAULT_CONFIG, { activeCreators: 6, seed: 111, limit: 12 }).map((x) => x.id).join(",");
  assert.equal(a, a2, "same seed is deterministic");
});

test("Personalization: topic affinity lifts matching content", () => {
  const base = {
    uniqViewers: 10, avgCompletion: 0.5, avgWatchMs: 15000, durationSec: 30, ageMs: DAY,
    creatorFollowers: 300, creatorId: "c", viewerCreatorFamiliarity: 0.2,
  };
  const music = scoreCandidate({ ...base, topics: ["music"] }, { topics: { music: 0.9 } }, DEFAULT_CONFIG);
  const unrelated = scoreCandidate({ ...base, topics: ["news"] }, { topics: { music: 0.9 } }, DEFAULT_CONFIG);
  assert.ok(music.signals.personalization > unrelated.signals.personalization);
  assert.ok(music.base > unrelated.base, "on-topic scores higher");
});

test("Anti-manipulation: inflated raw views don't inflate ranking", () => {
  const profile = { topics: {} };
  const honest = scoreCandidate({
    uniqViewers: 50, avgCompletion: 0.6, avgWatchMs: 18000, rawViews: 60, likeCount: 20, shareCount: 3,
    durationSec: 30, ageMs: DAY, creatorFollowers: 300, topics: ["x"], creatorId: "h",
  }, profile, DEFAULT_CONFIG);
  const botted = scoreCandidate({
    uniqViewers: 50, avgCompletion: 0.6, avgWatchMs: 18000, rawViews: 1000000, likeCount: 20, shareCount: 3,
    durationSec: 30, ageMs: DAY, creatorFollowers: 300, topics: ["x"], creatorId: "b",
  }, profile, DEFAULT_CONFIG);
  // Same real engagement -> effectively the same score despite 1M fake views.
  assert.ok(Math.abs(honest.base - botted.base) < 1e-9, "raw views are capped to distinct-viewer reality");
  assert.ok(botted.signals.effectiveViews <= 50 * DEFAULT_CONFIG.antiManipulation.maxViewsPerViewer);
});

test("Length-aware completion: a 10s clip watched fully < a 60s clip watched fully", () => {
  const profile = { topics: {} };
  const short = scoreCandidate({ uniqViewers: 10, avgCompletion: 1, avgWatchMs: 10000, durationSec: 10, ageMs: DAY, creatorId: "s" }, profile, DEFAULT_CONFIG);
  const long = scoreCandidate({ uniqViewers: 10, avgCompletion: 1, avgWatchMs: 60000, durationSec: 60, ageMs: DAY, creatorId: "l" }, profile, DEFAULT_CONFIG);
  assert.ok(long.signals.completion > short.signals.completion, "completion is length-normalized");
});

test("Negative signals: a viewer's prior skip/not-interested suppresses the video", () => {
  const profile = { topics: {} };
  const neutral = scoreCandidate({ uniqViewers: 10, avgCompletion: 0.6, durationSec: 30, ageMs: DAY, creatorId: "c" }, profile, DEFAULT_CONFIG);
  const notInterested = scoreCandidate({ uniqViewers: 10, avgCompletion: 0.6, durationSec: 30, ageMs: DAY, creatorId: "c", viewerNotInterested: true }, profile, DEFAULT_CONFIG);
  assert.ok(notInterested.base < neutral.base * 0.5, "'not interested' strongly suppresses");
});

test("Config is tunable via mergeConfig without mutating defaults", () => {
  const custom = mergeConfig({ composition: { discovery: 0.4 } });
  assert.equal(custom.composition.discovery, 0.4);
  assert.equal(custom.composition.personalized, 0.6, "unspecified keys keep defaults");
  assert.equal(DEFAULT_CONFIG.composition.discovery, 0.2, "defaults untouched");
});

test("Explainability: every recommendation carries a human-readable reason", () => {
  const sc = scoreCandidate({
    uniqViewers: 5, avgCompletion: 0.7, avgWatchMs: 20000, durationSec: 30, ageMs: 2 * HOUR,
    creatorFollowers: 50, topics: ["music"], creatorId: "c", viewerFollowsCreator: true,
  }, { topics: { music: 0.8 } }, DEFAULT_CONFIG);
  assert.ok(sc.reasons.length > 0);
  assert.ok(sc.reasons.some((r) => typeof r === "string" && r.length > 0));
});

// ---------------------------------------------------------------------------
// Stated targeting: a creator's chosen category and countries.
// ---------------------------------------------------------------------------

test("Category: a stated category the viewer chose beats guessed topics", () => {
  // Same video twice; only the viewer's declared interests differ.
  const cand = { category: "Dance", topics: [], uniqViewers: 5, avgCompletion: 0.5, avgWatchMs: 8000 };
  const matched = scoreCandidate(cand, { topics: {}, interests: new Set(["Dance"]) });
  const unmatched = scoreCandidate(cand, { topics: {}, interests: new Set(["Gaming"]) });

  assert.ok(matched.base > unmatched.base,
    "a category the viewer picked at signup must rank above one they didn't");
  assert.ok(matched.signals.categoryMatch === 1);
  assert.ok(matched.reasons.some((r) => r.includes("Dance")),
    "and it must be able to say so");
});

test("Country targeting damps but never excludes an untargeted viewer", () => {
  const cand = { countries: ["Rwanda"], topics: [], uniqViewers: 5, avgCompletion: 0.5, avgWatchMs: 8000 };
  const inside = scoreCandidate(cand, { topics: {}, country: "Rwanda" });
  const outside = scoreCandidate(cand, { topics: {}, country: "Kenya" });
  const unknown = scoreCandidate(cand, { topics: {}, country: null });

  assert.ok(inside.base > outside.base, "the targeted country should rank highest");
  // The important half: naming countries means "these especially", not
  // "nobody else". A hard filter would strand videos on a small platform.
  assert.ok(outside.base > 0, "an untargeted viewer stays eligible");
  assert.ok(unknown.base > outside.base,
    "a viewer with no country set must not be punished for it");
});

test("Untargeted videos are unaffected by country logic", () => {
  const cand = { topics: [], uniqViewers: 5, avgCompletion: 0.5, avgWatchMs: 8000 };
  const a = scoreCandidate({ ...cand, countries: [] }, { topics: {}, country: "Rwanda" });
  const b = scoreCandidate({ ...cand, countries: [] }, { topics: {}, country: "Kenya" });
  assert.equal(a.base, b.base, "a video with no target list ranks the same everywhere");
});
