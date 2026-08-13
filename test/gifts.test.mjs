import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// The gift prices live twice — once in the Worker, which CHARGES, and once in
// the Flutter app, which DISPLAYS. Nothing in either language can see the
// other, so the only thing that had been keeping them equal was somebody
// remembering to edit both.
//
// It stopped working: `rose` ended up in the Worker's list twice, at 2 coins
// and at 5. giftByKey takes the first match, so the app showed 5 and the
// server took 2 — and paid the creator on the 2. Five real gifts went out
// like that before it was noticed, because nothing anywhere compared the two
// lists.
//
// This does. Run with the rest:  node --test test/*.test.mjs
// (the glob, not the bare directory — this Node build tries to load a
// directory argument as a module and dies before running anything)
//
// Both files are read as TEXT rather than imported: src/index.js is a Worker
// module full of bindings that cannot be loaded in node, and the Dart file
// obviously cannot be imported at all. Parsing the literals is the only way
// to compare what each side actually ships.

const WORKER = "src/index.js";
const APP = "belople_app/lib/features/wallet/data/gift_repository.dart";

/// Pulls `{ key: "x", name: "X", coins: N, emoji: "…" }` out of the Worker's
/// GIFTS array.
function workerGifts() {
  const src = readFileSync(WORKER, "utf8");
  const start = src.indexOf("const GIFTS = [");
  assert.notEqual(start, -1, "GIFTS array not found in " + WORKER);
  const end = src.indexOf("];", start);
  const body = src.slice(start, end);

  const out = [];
  const re = /\{\s*key:\s*"([^"]+)"\s*,\s*name:\s*"([^"]+)"\s*,\s*coins:\s*(\d+)/g;
  let m;
  while ((m = re.exec(body))) out.push({ key: m[1], name: m[2], coins: Number(m[3]) });
  return out;
}

/// Pulls `Gift(key: 'x', name: 'X', coins: N, …)` out of the app's kGifts.
function appGifts() {
  const src = readFileSync(APP, "utf8");
  const start = src.indexOf("const List<Gift> kGifts = [");
  assert.notEqual(start, -1, "kGifts not found in " + APP);
  const end = src.indexOf("];", start);
  const body = src.slice(start, end);

  const out = [];
  const re = /Gift\(\s*key:\s*'([^']+)'\s*,\s*name:\s*'([^']+)'\s*,\s*coins:\s*(\d+)/g;
  let m;
  while ((m = re.exec(body))) out.push({ key: m[1], name: m[2], coins: Number(m[3]) });
  return out;
}

test("the Worker's gift keys are unique", () => {
  const keys = workerGifts().map(g => g.key);
  const dupes = keys.filter((k, i) => keys.indexOf(k) !== i);
  assert.deepEqual(
    [...new Set(dupes)], [],
    "giftByKey takes the first match, so a duplicate makes the later price unreachable"
  );
});

test("the app's gift keys are unique", () => {
  const keys = appGifts().map(g => g.key);
  const dupes = keys.filter((k, i) => keys.indexOf(k) !== i);
  assert.deepEqual([...new Set(dupes)], []);
});

test("the app shows exactly what the Worker charges", () => {
  const server = workerGifts();
  const app = appGifts();

  assert.ok(server.length > 0, "parsed no gifts from the Worker");
  assert.equal(
    app.length, server.length,
    `the app lists ${app.length} gifts and the Worker ${server.length}`
  );

  // Compared by key, not by position: the order on screen is a display
  // decision, but a price is not.
  for (const s of server) {
    const a = app.find(g => g.key === s.key);
    assert.ok(a, `the app is missing "${s.key}", which the Worker will happily charge for`);
    assert.equal(
      a.coins, s.coins,
      `"${s.key}": the app shows ${a.coins} coins and the Worker charges ${s.coins}`
    );
    assert.equal(a.name, s.name, `"${s.key}" is called "${a.name}" in the app and "${s.name}" on the server`);
  }

  for (const a of app) {
    assert.ok(
      server.find(g => g.key === a.key),
      `the app offers "${a.key}", which the Worker does not know and will reject`
    );
  }
});

test("gift prices only go up as the list goes down", () => {
  // Not cosmetic: the picker is read as a ladder, and a cheaper gift sitting
  // below a dearer one is how somebody sends more than they meant to.
  const server = workerGifts();
  for (let i = 1; i < server.length; i++) {
    assert.ok(
      server[i].coins >= server[i - 1].coins,
      `"${server[i].key}" (${server[i].coins}) is cheaper than "${server[i - 1].key}" (${server[i - 1].coins}) above it`
    );
  }
});
