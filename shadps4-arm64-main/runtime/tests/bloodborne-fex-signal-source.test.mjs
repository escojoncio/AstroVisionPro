import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const engineUrl = new URL("../../src/core/fex/fex_guest_engine.cpp", import.meta.url);
const signalsUrl = new URL("../../src/core/signals.cpp", import.meta.url);

test("GPU-tracking SIGSEGV bypasses FEX diagnostics and reaches normal dispatch", () => {
  const engine = readFileSync(engineUrl, "utf8");
  const signals = readFileSync(signalsUrl, "utf8");

  assert.match(signals, /case SIGBUS:\s*\n\s*case SIGSEGV:/);
  assert.match(
    signals,
    /sig == SIGBUS && ::Core::Fex::HandleGuestSignal\(sig, info, raw_context\)/,
  );

  assert.match(engine, /signal != SIGBUS/);
  assert.match(engine, /HandleUnalignedAccess/);
  assert.doesNotMatch(engine, /BACHATA_FEX_GUEST_FAULT/);
  // Only the read-only lookup for the crash dump may use it, never a signal-time state rewrite.
  const lookup = engine.match(
    /bool BachataQueryGuestRipAtHostPc\([\s\S]*?\n\}\n/,
  );
  assert.ok(lookup);
  assert.match(lookup[0], /RestoreRIPFromHostPC/);
  assert.doesNotMatch(engine.replace(lookup[0], ""), /RestoreRIPFromHostPC/);
});
