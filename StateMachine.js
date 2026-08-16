/**
 * StateMachine.js - pure on-air detection logic for omarchy-on-air.
 *
 * Loadable from QML (`import "StateMachine.js" as SM`) and from node
 * (`require("./StateMachine.js")`), so it contains top-level function
 * declarations only.
 *
 * There is no I/O and no `Date.now()` in here: every decision comes from the
 * `nowMs` the caller passes to `step()`, which makes the whole engine replayable
 * against synthetic traces (see StateMachine.test.js).
 *
 * The machine is plain JSON-serializable data. Config changes at runtime (the
 * user edits the ignore list or the timings mid-meeting) are applied by mutating
 * `machine.riseSeconds`, `machine.clearSeconds` or `machine.ignoreApps`; they
 * take effect on the next step.
 *
 * Model
 * -----
 * Each signal kind (audio, video) carries its own hysteresis window, exactly as
 * the SPEC's detection engine describes: a kind goes hot only after its raw
 * signal has been present continuously for `riseSeconds`, and cold only after
 * the raw signal has been absent continuously for `clearSeconds`. The debounced
 * per-kind booleans are then OR'd into the single on-air decision, so audio
 * arriving before video (or vice versa) cannot double-count or cancel out.
 *
 *   OFF_AIR --raw hot--> PENDING --sustained riseSeconds--> ON_AIR
 *   ON_AIR --raw quiet--> CLEARING --sustained clearSeconds--> OFF_AIR
 *   PENDING / CLEARING revert for free if the raw signal flips back first.
 */

/** Signal kinds that count as a capture. Anything else is ignored outright. */
function captureKinds() {
  return ["audio", "video"];
}

/**
 * @param {{riseSeconds?: number, clearSeconds?: number, ignoreApps?: string[]}} cfg
 * @returns {object} a fresh machine in OFF_AIR
 */
function createMachine(cfg) {
  const c = cfg || {};
  return {
    riseSeconds: positiveNumber(c.riseSeconds, 8),
    clearSeconds: positiveNumber(c.clearSeconds, 8),
    ignoreApps: Array.isArray(c.ignoreApps) ? c.ignoreApps.slice() : [],
    // Debounced on-air decision; the OR of the per-kind hot flags.
    onAir: false,
    // Per kind: `hot` is the debounced value, `edgeMs` is when the raw signal
    // started disagreeing with it (null when raw and debounced agree).
    kinds: { audio: newKindState(), video: newKindState() },
    lastStepMs: null
  };
}

/**
 * Advance the machine.
 *
 * @param {object} machine
 * @param {Array<{binary?: string, kind: string, app?: string}>} captures
 *        the CURRENT full set of capture holders, not a delta.
 * @param {number} nowMs wall-clock milliseconds.
 * @returns {{state: string, transition: string|null, activeApps: string[], nextWakeMs: number|null}}
 */
function step(machine, captures, nowMs) {
  // A gap far longer than the hysteresis windows means the host was suspended
  // (or the shell was frozen); the elapsed wall-clock time says nothing about
  // what the microphone was doing, so drop the windows and start them over.
  if (machine.lastStepMs !== null && nowMs - machine.lastStepMs > suspendGapMs(machine)) {
    forceResync(machine);
  }
  machine.lastStepMs = nowMs;

  const holders = activeHolders(machine, captures);
  const kinds = captureKinds();
  let nextWakeMs = null;

  for (let i = 0; i < kinds.length; i++) {
    const kind = kinds[i];
    const state = machine.kinds[kind];
    const raw = holders.some(function (h) {
      return h.kind === kind;
    });

    if (raw === state.hot) {
      state.edgeMs = null; // signal came back before the window elapsed
      continue;
    }
    if (state.edgeMs === null) {
      state.edgeMs = nowMs;
    }
    const windowMs = (raw ? machine.riseSeconds : machine.clearSeconds) * 1000;
    if (nowMs - state.edgeMs >= windowMs) {
      state.hot = raw;
      state.edgeMs = null;
    } else {
      nextWakeMs = earlier(nextWakeMs, state.edgeMs + windowMs);
    }
  }

  const onAir = machine.kinds.audio.hot || machine.kinds.video.hot;
  let transition = null;
  if (onAir !== machine.onAir) {
    machine.onAir = onAir;
    transition = onAir ? "to_on_air" : "to_off_air";
  }

  return {
    state: describeState(machine),
    transition: transition,
    activeApps: displayNames(holders),
    nextWakeMs: nextWakeMs
  };
}

/**
 * Seed the machine as already settled on-air for whichever kinds are capturing
 * right now, skipping the rise window entirely.
 *
 * Startup adoption only: a snapshot left behind by a previous shell process
 * plus a live capture means the meeting has demonstrably been running longer
 * than `riseSeconds` already. Re-running the countdown from a fresh machine
 * would report PENDING for a meeting that is plainly underway — and since the
 * light is already red, the widget would contradict the bulb for the length of
 * the window.
 *
 * @returns {boolean} whether anything was adopted (i.e. a capture is live).
 */
function adopt(machine, captures) {
  const holders = activeHolders(machine, captures);
  const kinds = captureKinds();
  let any = false;
  for (let i = 0; i < kinds.length; i++) {
    const kind = kinds[i];
    const raw = holders.some(function (h) {
      return h.kind === kind;
    });
    machine.kinds[kind].hot = raw;
    machine.kinds[kind].edgeMs = null;
    if (raw) any = true;
  }
  machine.onAir = any;
  return any;
}

/**
 * Drop the in-flight hysteresis windows, keeping the ON_AIR/OFF_AIR base state.
 * Used after a suspend/resume or a monitor restart, where the pending window
 * measured across the gap is meaningless but the last known base state is not.
 */
function forceResync(machine) {
  const kinds = captureKinds();
  for (let i = 0; i < kinds.length; i++) {
    machine.kinds[kinds[i]].edgeMs = null;
  }
}

// --- internals -------------------------------------------------------------

function newKindState() {
  return { hot: false, edgeMs: null };
}

function positiveNumber(value, fallback) {
  if (typeof value !== "number" || !isFinite(value) || value < 0) {
    return fallback;
  }
  return value;
}

function suspendGapMs(machine) {
  return 3 * Math.max(machine.riseSeconds, machine.clearSeconds) * 1000;
}

function earlier(a, b) {
  return a === null || b < a ? b : a;
}

/** Non-ignored capture holders of a kind we understand. */
function activeHolders(machine, captures) {
  const list = Array.isArray(captures) ? captures : [];
  const ignored = lowercased(machine.ignoreApps);
  const out = [];
  for (let i = 0; i < list.length; i++) {
    const capture = list[i];
    if (!capture || captureKinds().indexOf(capture.kind) === -1) {
      continue;
    }
    const binary = typeof capture.binary === "string" ? capture.binary : "";
    if (ignored.indexOf(binary.toLowerCase()) !== -1) {
      continue;
    }
    out.push({ kind: capture.kind, name: capture.app || binary || "unknown" });
  }
  return out;
}

function lowercased(values) {
  const out = [];
  const list = Array.isArray(values) ? values : [];
  for (let i = 0; i < list.length; i++) {
    if (typeof list[i] === "string") {
      out.push(list[i].toLowerCase());
    }
  }
  return out;
}

/** Display names, deduplicated, in first-seen order. */
function displayNames(holders) {
  const out = [];
  for (let i = 0; i < holders.length; i++) {
    if (out.indexOf(holders[i].name) === -1) {
      out.push(holders[i].name);
    }
  }
  return out;
}

function describeState(machine) {
  const kinds = captureKinds();
  let settledHot = false;
  let rising = false;
  for (let i = 0; i < kinds.length; i++) {
    const state = machine.kinds[kinds[i]];
    if (state.hot && state.edgeMs === null) {
      settledHot = true;
    }
    if (!state.hot && state.edgeMs !== null) {
      rising = true;
    }
  }
  if (machine.onAir) {
    // On-air with every hot kind counting down means we are on the way out.
    return settledHot ? "ON_AIR" : "CLEARING";
  }
  return rising ? "PENDING" : "OFF_AIR";
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { createMachine: createMachine, step: step, adopt: adopt, forceResync: forceResync };
}
