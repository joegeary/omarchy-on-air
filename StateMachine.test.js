/**
 * StateMachine.test.js - node test suite for StateMachine.js.
 *
 *   node StateMachine.test.js        # exits nonzero on the first failing suite
 *
 * No dependencies, no real clock: every trace drives an explicit fake timeline,
 * so hysteresis edges are asserted to the millisecond.
 */

const SM = require("./StateMachine.js");

// --- tiny harness ----------------------------------------------------------

let passed = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (err) {
    failures.push({ name: name, message: err && err.message ? err.message : String(err) });
  }
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message || "assertion failed");
  }
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error((message ? message + ": " : "") + "expected " + json(expected) + ", got " + json(actual));
  }
}

function assertDeepEqual(actual, expected, message) {
  if (json(actual) !== json(expected)) {
    throw new Error((message ? message + ": " : "") + "expected " + json(expected) + ", got " + json(actual));
  }
}

function json(value) {
  return JSON.stringify(value);
}

/** Assert the shape of a step() result in one line. */
function assertStep(result, state, transition, message) {
  assertEqual(result.state, state, (message || "") + " state");
  assertEqual(result.transition, transition, (message || "") + " transition");
}

// --- fixtures --------------------------------------------------------------

function audio(binary, app) {
  return { binary: binary, kind: "audio", app: app };
}

function video(binary, app) {
  return { binary: binary, kind: "video", app: app };
}

function machine(overrides) {
  const cfg = { riseSeconds: 8, clearSeconds: 8, ignoreApps: ["obs", "voxtype"] };
  for (const key in overrides || {}) {
    cfg[key] = overrides[key];
  }
  return SM.createMachine(cfg);
}

/**
 * Step repeatedly with a fixed capture set, always sleeping exactly until the
 * nextWakeMs the machine asked for - i.e. what the Service.qml timer does.
 * Returns every result, so a trace can be asserted end to end.
 */
function sleepUntilIdle(m, captures, startMs, maxSteps) {
  const results = [];
  let now = startMs;
  let result = SM.step(m, captures, now);
  results.push({ t: now, state: result.state, transition: result.transition });
  let guard = 0;
  while (result.nextWakeMs !== null) {
    if (++guard > (maxSteps || 10)) {
      throw new Error("nextWakeMs never settled: " + json(results));
    }
    now = result.nextWakeMs;
    result = SM.step(m, captures, now);
    results.push({ t: now, state: result.state, transition: result.transition });
  }
  return results;
}

function transitionsOf(results) {
  return results
    .filter(function (r) {
      return r.transition !== null;
    })
    .map(function (r) {
      return r.transition;
    });
}

// --- config ----------------------------------------------------------------

test("createMachine applies documented defaults", function () {
  const m = SM.createMachine({});
  assertEqual(m.riseSeconds, 8, "riseSeconds");
  assertEqual(m.clearSeconds, 8, "clearSeconds");
  assertDeepEqual(m.ignoreApps, [], "ignoreApps");
  assertEqual(m.onAir, false, "onAir");
  assertEqual(SM.step(m, [], 0).state, "OFF_AIR", "initial state");
});

test("createMachine tolerates a missing or malformed cfg", function () {
  assertEqual(SM.createMachine().riseSeconds, 8, "no cfg");
  assertEqual(SM.createMachine({ riseSeconds: -4 }).riseSeconds, 8, "negative");
  assertEqual(SM.createMachine({ clearSeconds: "12" }).clearSeconds, 8, "string");
  assertEqual(SM.createMachine({ riseSeconds: 0 }).riseSeconds, 0, "zero is legal");
});

test("machine stays plain JSON round-trippable across a shell restart", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 1000);
  const revived = JSON.parse(JSON.stringify(m));
  assertDeepEqual(revived, m, "round trip");
  // A revived machine keeps counting from where the original left off.
  assertStep(SM.step(revived, [audio("zoom")], 9000), "ON_AIR", "to_on_air");
});

// --- rise hysteresis -------------------------------------------------------

test("rise: just under riseSeconds stays PENDING", function () {
  const m = machine();
  assertStep(SM.step(m, [audio("zoom")], 1000), "PENDING", null, "start");
  assertStep(SM.step(m, [audio("zoom")], 8999), "PENDING", null, "1ms short");
  assertEqual(m.onAir, false, "onAir");
});

test("rise: exactly riseSeconds crosses to ON_AIR", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 1000);
  assertStep(SM.step(m, [audio("zoom")], 9000), "ON_AIR", "to_on_air", "exact edge");
});

test("rise: a step past the window crosses on that step, not retroactively", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 1000);
  assertStep(SM.step(m, [audio("zoom")], 8999), "PENDING", null, "before");
  assertStep(SM.step(m, [audio("zoom")], 9001), "ON_AIR", "to_on_air", "after");
  assertStep(SM.step(m, [audio("zoom")], 9002), "ON_AIR", null, "settled");
});

test("rise: window restarts from scratch when the signal drops out", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 7000);
  assertStep(SM.step(m, [], 7500), "OFF_AIR", null, "dropped at 7.5s");
  assertStep(SM.step(m, [audio("zoom")], 8000), "PENDING", null, "restarted");
  assertStep(SM.step(m, [audio("zoom")], 15999), "PENDING", null, "old deadline passed");
  assertStep(SM.step(m, [audio("zoom")], 16000), "ON_AIR", "to_on_air", "new deadline");
});

test("rise: riseSeconds 0 goes on-air on the first hot step", function () {
  const m = machine({ riseSeconds: 0 });
  assertStep(SM.step(m, [audio("zoom")], 1234), "ON_AIR", "to_on_air", "immediate");
});

// --- clear hysteresis ------------------------------------------------------

test("clear: just under clearSeconds stays CLEARING", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 8000);
  assertStep(SM.step(m, [], 10000), "CLEARING", null, "quiet");
  assertStep(SM.step(m, [], 17999), "CLEARING", null, "1ms short");
  assertEqual(m.onAir, true, "still on air");
});

test("clear: exactly clearSeconds crosses to OFF_AIR", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 8000);
  SM.step(m, [], 10000);
  assertStep(SM.step(m, [], 18000), "OFF_AIR", "to_off_air", "exact edge");
  assertStep(SM.step(m, [], 19000), "OFF_AIR", null, "settled");
});

test("clear: separate rise and clear windows are honoured independently", function () {
  const m = machine({ riseSeconds: 2, clearSeconds: 20 });
  assertStep(SM.step(m, [audio("zoom")], 0), "PENDING", null, "t0");
  assertStep(SM.step(m, [audio("zoom")], 2000), "ON_AIR", "to_on_air", "rise 2s");
  assertStep(SM.step(m, [], 3000), "CLEARING", null, "quiet");
  assertStep(SM.step(m, [], 22999), "CLEARING", null, "clear not yet");
  assertStep(SM.step(m, [], 23000), "OFF_AIR", "to_off_air", "clear 20s");
});

// --- flapping --------------------------------------------------------------

test("mute-toggle flapping inside the clear window never leaves ON_AIR", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 8000);
  const results = [];
  // Mute/unmute every two seconds for a minute.
  for (let i = 0; i < 30; i++) {
    const t = 10000 + i * 2000;
    results.push(SM.step(m, i % 2 === 0 ? [] : [audio("zoom")], t));
  }
  const seen = results.map(function (r) {
    return r.transition;
  });
  assertDeepEqual(
    seen.filter(function (t) {
      return t !== null;
    }),
    [],
    "no transitions"
  );
  assertEqual(m.onAir, true, "still on air");
  assertStep(SM.step(m, [audio("zoom")], 80000), "ON_AIR", null, "after flapping");
});

test("flapping below riseSeconds never reaches ON_AIR", function () {
  const m = machine();
  for (let i = 0; i < 20; i++) {
    const t = i * 3000;
    const result = SM.step(m, i % 2 === 0 ? [audio("zoom")] : [], t);
    assertEqual(result.transition, null, "transition at t=" + t);
    assertEqual(result.state, i % 2 === 0 ? "PENDING" : "OFF_AIR", "state at t=" + t);
  }
});

// --- ignore list -----------------------------------------------------------

test("an ignored app alone never triggers", function () {
  const m = machine();
  const results = sleepUntilIdle(m, [audio("obs"), video("obs")], 0);
  assertDeepEqual(transitionsOf(results), [], "transitions");
  assertEqual(results[results.length - 1].state, "OFF_AIR", "state");
  assertEqual(results.length, 1, "no wake scheduled");
  assertDeepEqual(results, [{ t: 0, state: "OFF_AIR", transition: null }], "trace");
});

test("ignore matching is case-insensitive on the binary", function () {
  const m = machine({ ignoreApps: ["OBS", "VoxType"] });
  const result = SM.step(m, [audio("obs"), audio("voxtype")], 0);
  assertEqual(result.state, "OFF_AIR", "state");
  assertDeepEqual(result.activeApps, [], "activeApps");
  assertEqual(SM.step(m, [audio("OBS")], 1000).state, "OFF_AIR", "uppercase capture");
});

test("ignore matches the binary, never the friendly app name", function () {
  const m = machine({ ignoreApps: ["obs"] });
  // A capture whose app label is "OBS" but whose binary is not on the list counts.
  assertStep(SM.step(m, [audio("chromium", "OBS")], 0), "PENDING", null, "labelled OBS");
});

test("an ignored app mixed with a real one still goes on-air", function () {
  const m = machine();
  const captures = [audio("obs"), audio("zoom", "Zoom")];
  assertStep(SM.step(m, captures, 0), "PENDING", null, "t0");
  const result = SM.step(m, captures, 8000);
  assertStep(result, "ON_AIR", "to_on_air", "t8");
  assertDeepEqual(result.activeApps, ["Zoom"], "ignored app hidden");
});

test("adding the active app to ignoreApps mid-meeting clears the machine", function () {
  const m = machine();
  const captures = [audio("zoom", "Zoom")];
  SM.step(m, captures, 0);
  assertStep(SM.step(m, captures, 8000), "ON_AIR", "to_on_air", "on air");

  m.ignoreApps.push("zoom"); // e.g. `on-air ignore add zoom` -> config reload
  const clearing = SM.step(m, captures, 9000);
  assertStep(clearing, "CLEARING", null, "ignored mid-meeting");
  assertDeepEqual(clearing.activeApps, [], "activeApps");
  assertEqual(clearing.nextWakeMs, 17000, "clear deadline");
  assertStep(SM.step(m, captures, 17000), "OFF_AIR", "to_off_air", "cleared");
});

test("removing an app from ignoreApps mid-capture starts a fresh rise", function () {
  const m = machine({ ignoreApps: ["zoom"] });
  const captures = [audio("zoom", "Zoom")];
  assertStep(SM.step(m, captures, 0), "OFF_AIR", null, "ignored");
  assertStep(SM.step(m, captures, 60000), "OFF_AIR", null, "still ignored");

  m.ignoreApps = []; // unignore
  assertStep(SM.step(m, captures, 61000), "PENDING", null, "rise starts now");
  assertStep(SM.step(m, captures, 68999), "PENDING", null, "not yet");
  assertStep(SM.step(m, captures, 69000), "ON_AIR", "to_on_air", "8s later");
});

// --- audio / video independence -------------------------------------------

test("audio and video windows run independently and OR together", function () {
  const m = machine();
  // Video starts 5s after audio; audio alone is enough at t=8000.
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom"), video("zoom")], 5000);
  assertStep(SM.step(m, [audio("zoom"), video("zoom")], 8000), "ON_AIR", "to_on_air", "audio wins");
  // Audio stops at 9000 (clear deadline 17000); video went hot at 13000.
  assertStep(SM.step(m, [video("zoom")], 9000), "CLEARING", null, "audio falling");
  assertStep(SM.step(m, [video("zoom")], 13000), "ON_AIR", null, "video hot, no transition");
  assertStep(SM.step(m, [video("zoom")], 17000), "ON_AIR", null, "audio cold, video holds");
  assertEqual(m.kinds.audio.hot, false, "audio debounced cold");
  assertEqual(m.kinds.video.hot, true, "video debounced hot");
});

test("camera-only capture drives a full cycle", function () {
  const m = machine();
  const results = sleepUntilIdle(m, [video("cheese", "Cheese")], 0);
  assertDeepEqual(transitionsOf(results), ["to_on_air"], "on air from video alone");
  const off = sleepUntilIdle(m, [], 20000);
  assertDeepEqual(transitionsOf(off), ["to_off_air"], "off air from video alone");
});

test("an unknown capture kind is ignored entirely", function () {
  const m = machine();
  const result = SM.step(m, [{ binary: "zoom", kind: "midi" }], 0);
  assertStep(result, "OFF_AIR", null, "unknown kind");
  assertDeepEqual(result.activeApps, [], "activeApps");
  assertEqual(result.nextWakeMs, null, "nextWakeMs");
});

// --- overlapping meetings --------------------------------------------------

test("overlapping meetings: a second app joining before the first leaves holds ON_AIR", function () {
  const m = machine();
  const zoom = audio("zoom", "Zoom");
  const teams = audio("teams-for-linux", "Teams");

  SM.step(m, [zoom], 0);
  assertStep(SM.step(m, [zoom], 8000), "ON_AIR", "to_on_air", "first meeting");

  const both = SM.step(m, [zoom, teams], 60000);
  assertStep(both, "ON_AIR", null, "second joins");
  assertDeepEqual(both.activeApps, ["Zoom", "Teams"], "both listed");
  assertEqual(both.nextWakeMs, null, "no pending window");

  const second = SM.step(m, [teams], 90000);
  assertStep(second, "ON_AIR", null, "first leaves");
  assertDeepEqual(second.activeApps, ["Teams"], "only the survivor");

  const results = sleepUntilIdle(m, [], 120000);
  assertDeepEqual(transitionsOf(results), ["to_off_air"], "exactly one off-air crossing");
});

test("overlapping meetings across kinds never blink off-air", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 8000); // ON_AIR
  // Video app joins at 10s (hot at 18s); audio leaves at 12s (cold at 20s).
  SM.step(m, [audio("zoom"), video("chromium")], 10000);
  SM.step(m, [video("chromium")], 12000);
  assertStep(SM.step(m, [video("chromium")], 18000), "ON_AIR", null, "video hot first");
  assertStep(SM.step(m, [video("chromium")], 20000), "ON_AIR", null, "audio expiry absorbed");
  assertEqual(m.onAir, true, "never dropped");
});

// --- suspend / resync ------------------------------------------------------

test("suspend gap from CLEARING restarts the clear window instead of expiring it", function () {
  const m = machine(); // suspend threshold = 3 * 8s = 24s
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 8000);
  const clearing = SM.step(m, [], 10000);
  assertEqual(clearing.nextWakeMs, 18000, "pre-suspend deadline");

  const resumed = SM.step(m, [], 35000); // 25s gap > 24s threshold
  assertStep(resumed, "CLEARING", null, "resumed");
  assertEqual(resumed.nextWakeMs, 43000, "window restarted at resume");
  assertStep(SM.step(m, [], 42999), "CLEARING", null, "still clearing");
  assertStep(SM.step(m, [], 43000), "OFF_AIR", "to_off_air", "cleared after resume");
});

test("suspend gap from ON_AIR with capture still held keeps ON_AIR silently", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 8000);
  const resumed = SM.step(m, [audio("zoom")], 3600000);
  assertStep(resumed, "ON_AIR", null, "adopted after resume");
  assertEqual(resumed.nextWakeMs, null, "idle");
});

test("suspend gap from PENDING restarts the rise window", function () {
  const m = machine();
  const captures = [audio("zoom")];
  const pending = SM.step(m, captures, 0);
  assertEqual(pending.nextWakeMs, 8000, "pre-suspend deadline");

  const resumed = SM.step(m, captures, 30000); // 30s gap > 24s threshold
  assertStep(resumed, "PENDING", null, "still pending after resume");
  assertEqual(resumed.nextWakeMs, 38000, "window restarted at resume");
  assertStep(SM.step(m, captures, 37999), "PENDING", null, "not yet");
  assertStep(SM.step(m, captures, 38000), "ON_AIR", "to_on_air", "full window served");
});

test("suspend gap that resumes off-air with no capture goes straight to OFF_AIR", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0); // PENDING
  const resumed = SM.step(m, [], 30000);
  assertStep(resumed, "OFF_AIR", null, "no crossing ever happened");
  assertEqual(resumed.nextWakeMs, null, "idle");
});

test("a gap just under 3x the larger window is NOT treated as suspend", function () {
  const m = machine({ riseSeconds: 8, clearSeconds: 10 }); // threshold = 30s
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 8000);
  SM.step(m, [], 10000); // CLEARING, deadline 20000
  assertStep(SM.step(m, [], 40000), "OFF_AIR", "to_off_air", "30s gap is not suspend");
});

test("forceResync keeps the base state and drops the in-flight window", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [audio("zoom")], 8000);
  SM.step(m, [], 10000); // CLEARING
  SM.forceResync(m);
  assertEqual(m.onAir, true, "base state kept");
  assertEqual(m.kinds.audio.edgeMs, null, "window dropped");
  const after = SM.step(m, [], 11000);
  assertStep(after, "CLEARING", null, "re-evaluated from scratch");
  assertEqual(after.nextWakeMs, 19000, "window restarted");
});

test("forceResync from PENDING drops back to OFF_AIR until the signal is re-seen", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  SM.forceResync(m);
  assertEqual(m.onAir, false, "base state kept");
  assertStep(SM.step(m, [audio("zoom")], 1000), "PENDING", null, "window restarted");
  assertStep(SM.step(m, [audio("zoom")], 8999), "PENDING", null, "old deadline void");
  assertStep(SM.step(m, [audio("zoom")], 9000), "ON_AIR", "to_on_air", "new deadline");
});

// --- transitions -----------------------------------------------------------

test("each crossing reports its transition exactly once", function () {
  const m = machine();
  const seen = [];
  const timeline = [
    [0, [audio("zoom")]],
    [4000, [audio("zoom")]],
    [8000, [audio("zoom")]],
    [12000, [audio("zoom")]],
    [16000, [audio("zoom")]],
    [20000, []],
    [24000, []],
    [28000, []],
    [32000, []],
    [40000, [audio("zoom")]],
    [48000, [audio("zoom")]],
    [56000, [audio("zoom")]],
    [60000, []],
    [70000, []]
  ];
  for (let i = 0; i < timeline.length; i++) {
    const result = SM.step(m, timeline[i][1], timeline[i][0]);
    if (result.transition !== null) {
      seen.push([timeline[i][0], result.transition]);
    }
  }
  assertDeepEqual(
    seen,
    [
      [8000, "to_on_air"],
      [28000, "to_off_air"],
      [48000, "to_on_air"],
      [70000, "to_off_air"]
    ],
    "crossings"
  );
});

test("stepping repeatedly at the same timestamp does not re-fire a transition", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0);
  assertStep(SM.step(m, [audio("zoom")], 8000), "ON_AIR", "to_on_air", "first");
  assertStep(SM.step(m, [audio("zoom")], 8000), "ON_AIR", null, "repeat");
  assertStep(SM.step(m, [audio("zoom")], 8000), "ON_AIR", null, "repeat again");
});

// --- activeApps ------------------------------------------------------------

test("activeApps prefers the friendly app name and falls back to the binary", function () {
  const m = machine();
  const result = SM.step(m, [audio("zoom", "Zoom"), audio("some-unknown-binary")], 0);
  assertDeepEqual(result.activeApps, ["Zoom", "some-unknown-binary"], "names");
});

test("activeApps deduplicates a holder that owns both mic and camera", function () {
  const m = machine();
  const result = SM.step(m, [audio("zoom", "Zoom"), video("zoom", "Zoom")], 0);
  assertDeepEqual(result.activeApps, ["Zoom"], "deduped");
});

test("activeApps reports live holders even while OFF_AIR or CLEARING", function () {
  const m = machine();
  assertDeepEqual(SM.step(m, [audio("zoom", "Zoom")], 0).activeApps, ["Zoom"], "pending");
  SM.step(m, [audio("zoom", "Zoom")], 8000);
  assertDeepEqual(SM.step(m, [], 9000).activeApps, [], "clearing with nobody left");
});

test("a nameless capture degrades to a placeholder instead of undefined", function () {
  const m = machine();
  assertDeepEqual(SM.step(m, [{ kind: "audio" }], 0).activeApps, ["unknown"], "placeholder");
});

test("step tolerates null captures and leaves the caller's array untouched", function () {
  const m = machine();
  assertStep(SM.step(m, null, 0), "OFF_AIR", null, "null captures");
  const captures = [audio("zoom", "Zoom")];
  const snapshot = json(captures);
  SM.step(m, captures, 1000);
  assertEqual(json(captures), snapshot, "captures unmodified");
});

// --- nextWakeMs ------------------------------------------------------------

test("nextWakeMs is null when idle and set while a window is running", function () {
  const m = machine();
  assertEqual(SM.step(m, [], 0).nextWakeMs, null, "idle off-air");
  assertEqual(SM.step(m, [audio("zoom")], 1000).nextWakeMs, 9000, "rise deadline");
  assertEqual(SM.step(m, [audio("zoom")], 9000).nextWakeMs, null, "idle on-air");
  assertEqual(SM.step(m, [], 10000).nextWakeMs, 18000, "clear deadline");
});

test("nextWakeMs reports the earliest of two running windows", function () {
  const m = machine();
  SM.step(m, [audio("zoom")], 0); // audio rise deadline 8000
  const result = SM.step(m, [audio("zoom"), video("zoom")], 3000); // video deadline 11000
  assertEqual(result.nextWakeMs, 8000, "earliest deadline");
});

test("sleeping exactly until nextWakeMs still crosses the boundary (rise)", function () {
  const m = machine();
  const results = sleepUntilIdle(m, [audio("zoom", "Zoom")], 1000);
  assertDeepEqual(
    results,
    [
      { t: 1000, state: "PENDING", transition: null },
      { t: 9000, state: "ON_AIR", transition: "to_on_air" }
    ],
    "trace"
  );
});

test("sleeping exactly until nextWakeMs still crosses the boundary (clear)", function () {
  const m = machine({ riseSeconds: 3, clearSeconds: 12 });
  sleepUntilIdle(m, [audio("zoom")], 0);
  const results = sleepUntilIdle(m, [], 5000);
  assertDeepEqual(
    results,
    [
      { t: 5000, state: "CLEARING", transition: null },
      { t: 17000, state: "OFF_AIR", transition: "to_off_air" }
    ],
    "trace"
  );
});

test("a wake-driven caller converges in one wake per running window", function () {
  const m = machine();
  // Audio then video, staggered: two windows, so at most two wakes to settle.
  SM.step(m, [audio("zoom")], 0);
  const results = sleepUntilIdle(m, [audio("zoom"), video("zoom")], 3000, 3);
  assertEqual(results[results.length - 1].state, "ON_AIR", "settled");
  assert(results.length <= 3, "converged in " + results.length + " steps");
});

// --- startup adoption ------------------------------------------------------

test("adopt lands straight in ON_AIR without a rise window", function () {
  const m = machine();
  assert(SM.adopt(m, [audio("zoom")]), "adopted a live capture");
  const result = SM.step(m, [audio("zoom")], 0);
  assertEqual(result.state, "ON_AIR", "no PENDING flash after a mid-meeting restart");
  assertEqual(result.transition, null, "adoption is not a fresh to_on_air transition");
  assertEqual(result.nextWakeMs, null, "no window left running");
});

test("adopt seeds only the kinds actually capturing", function () {
  const m = machine();
  SM.adopt(m, [video("teams-for-linux")]);
  assertEqual(m.kinds.video.hot, true, "video hot");
  assertEqual(m.kinds.audio.hot, false, "audio untouched");
  // Dropping the camera still has to serve the full clear window.
  assertEqual(SM.step(m, [], 0).state, "CLEARING", "clearing, not off");
  assertEqual(SM.step(m, [], 7999).state, "CLEARING", "still inside the window");
  assertEqual(SM.step(m, [], 8000).state, "OFF_AIR", "off at the clear edge");
});

test("adopt with nothing capturing reports false and stays off-air", function () {
  const m = machine();
  assertEqual(SM.adopt(m, []), false, "nothing to adopt");
  assertEqual(SM.step(m, [], 0).state, "OFF_AIR", "off-air");
});

test("adopt ignores the ignore-list, so an ignored app never adopts", function () {
  const m = machine();
  assertEqual(SM.adopt(m, [audio("obs")]), false, "obs is on the ignore list");
  assertEqual(SM.step(m, [audio("obs")], 0).state, "OFF_AIR", "still off-air");
});

test("an adopted meeting that ends still fires to_off_air for the reconciler", function () {
  const m = machine();
  SM.adopt(m, [audio("zoom")]);
  SM.step(m, [audio("zoom")], 0);
  SM.step(m, [], 1000);
  const result = SM.step(m, [], 9000);
  assertEqual(result.state, "OFF_AIR", "off-air");
  assertEqual(result.transition, "to_off_air", "transition fires so the lights get restored");
});

// --- report ----------------------------------------------------------------

const total = passed + failures.length;
for (let i = 0; i < failures.length; i++) {
  console.error("FAIL " + failures[i].name + "\n      " + failures[i].message);
}
console.log(passed + "/" + total + " tests passed");
if (failures.length > 0) {
  process.exit(1);
}
