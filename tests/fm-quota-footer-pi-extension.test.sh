#!/usr/bin/env bash
# Tests for the tracked Pi quota-footer extension
# (.pi/extensions/fm-quota-footer.ts): parsing quota-axi --json output,
# footer formatting, and refresh/cleanup lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/.pi/extensions/fm-quota-footer.ts"
export NODE_NO_WARNINGS=1

assert_present "$EXT" "fm-quota-footer.ts extension is missing"

test_extract_all_models_percent() {
  EXT_PATH="$EXT" node --input-type=module >/tmp/fm-quota-footer-parse.out 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);

const fixture = JSON.stringify({
  providers: [
    {
      provider: "claude",
      quotaSemantics: {
        effectiveAvailability: [
          { scope: "all_models", effectivePercentRemaining: 28 },
          { scope: "model:fable", effectivePercentRemaining: 7 },
        ],
      },
    },
    {
      provider: "codex",
      quotaSemantics: {
        effectiveAvailability: [
          { scope: "all_models", effectivePercentRemaining: 63 },
        ],
      },
    },
  ],
});

const claude = mod.extractAllModelsPercent(fixture, "claude");
const codex = mod.extractAllModelsPercent(fixture, "codex");
if (claude !== 28) throw new Error("expected claude 28, got " + claude);
if (codex !== 63) throw new Error("expected codex 63, got " + codex);

const missingProvider = mod.extractAllModelsPercent(fixture, "cursor");
if (missingProvider !== undefined) throw new Error("expected undefined for missing provider, got " + missingProvider);

const missingScope = mod.extractAllModelsPercent(
  JSON.stringify({ providers: [{ provider: "claude", quotaSemantics: { effectiveAvailability: [] } }] }),
  "claude",
);
if (missingScope !== undefined) throw new Error("expected undefined for missing all_models row, got " + missingScope);

const malformed = mod.extractAllModelsPercent("not json", "claude");
if (malformed !== undefined) throw new Error("expected undefined for malformed JSON, got " + malformed);

console.log("ok");
EOF
  expect_code 0 $? "extractAllModelsPercent behavior: $(cat /tmp/fm-quota-footer-parse.out)"
  grep -q "^ok$" /tmp/fm-quota-footer-parse.out || fail "extractAllModelsPercent did not confirm ok: $(cat /tmp/fm-quota-footer-parse.out)"
  pass "quota footer: extractAllModelsPercent reads all_models rows and returns undefined on missing/malformed input"
}

test_format_quota_footer() {
  EXT_PATH="$EXT" node --input-type=module >/tmp/fm-quota-footer-format.out 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);

const both = mod.formatQuotaFooter({ claude: 28, codex: 63 });
if (both !== "Claude 28% left · GPT 63% left") throw new Error("unexpected: " + both);

const missingCodex = mod.formatQuotaFooter({ claude: 28, codex: undefined });
if (missingCodex !== "Claude 28% left · GPT n/a left") throw new Error("unexpected: " + missingCodex);

const missingBoth = mod.formatQuotaFooter({ claude: undefined, codex: undefined });
if (missingBoth !== "Claude n/a left · GPT n/a left") throw new Error("unexpected: " + missingBoth);

const rounds = mod.formatQuotaFooter({ claude: 27.6, codex: 62.4 });
if (rounds !== "Claude 28% left · GPT 62% left") throw new Error("unexpected: " + rounds);

console.log("ok");
EOF
  expect_code 0 $? "formatQuotaFooter behavior: $(cat /tmp/fm-quota-footer-format.out)"
  grep -q "^ok$" /tmp/fm-quota-footer-format.out || fail "formatQuotaFooter did not confirm ok: $(cat /tmp/fm-quota-footer-format.out)"
  pass "quota footer: formatQuotaFooter renders Claude/GPT percentages and n/a for missing values"
}

test_refresh_and_shutdown_lifecycle() {
  local dir fakebin out
  dir=$(fm_test_tmproot fm-quota-footer-lifecycle)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":40}]}}]}
JSON
exit 0
SH
  chmod +x "$fakebin/quota-axi"

  PATH="$fakebin:$PATH" EXT_PATH="$EXT" node --input-type=module >/tmp/fm-quota-footer-lifecycle.out 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);

const statuses = [];
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });

const ui = {
  setStatus: (key, text) => statuses.push([key, text]),
};

await handlers["session_start"]({ reason: "startup" }, { ui });
// Let the async refresh's child_process close event settle.
await new Promise((resolve) => setTimeout(resolve, 500));

const setCalls = statuses.filter(([, text]) => text !== undefined);
if (setCalls.length !== 1) throw new Error("expected exactly one status set, got " + JSON.stringify(statuses));
if (setCalls[0][1] !== "Claude 40% left · GPT n/a left") throw new Error("unexpected status: " + setCalls[0][1]);

handlers["session_shutdown"]({ reason: "quit" }, { ui });
const last = statuses[statuses.length - 1];
if (last[1] !== undefined) throw new Error("expected status cleared on shutdown, got " + JSON.stringify(last));

console.log("ok");
EOF
  expect_code 0 $? "refresh/shutdown lifecycle: $(cat /tmp/fm-quota-footer-lifecycle.out)"
  grep -q "^ok$" /tmp/fm-quota-footer-lifecycle.out || fail "refresh/shutdown lifecycle did not confirm ok: $(cat /tmp/fm-quota-footer-lifecycle.out)"
  pass "quota footer: session_start refreshes the footer status and session_shutdown clears it"
}

test_shutdown_during_refresh_and_replacement_start() {
  local dir fakebin started count
  dir=$(fm_test_tmproot fm-quota-footer-generation)
  fakebin="$dir/fakebin"
  started="$dir/started"
  count="$dir/count"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "$COUNT_FILE" ]]; then
  read -r count < "$COUNT_FILE"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$COUNT_FILE"
if [[ "$count" -eq 1 ]]; then
  touch "$STARTED_FILE"
  sleep 0.5
  percent=40
else
  percent=70
fi
printf '{"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":%s}]}}]}\n' "$percent"
SH
  chmod +x "$fakebin/quota-axi"

  PATH="$fakebin:$PATH" EXT_PATH="$EXT" STARTED_FILE="$started" COUNT_FILE="$count" \
    node --input-type=module >/tmp/fm-quota-footer-generation.out 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);

const statuses = [];
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });

const ui = {
  setStatus: (key, text) => statuses.push([key, text]),
};

handlers["session_start"]({ reason: "startup" }, { ui });
for (let attempt = 0; attempt < 100 && !existsSync(process.env.STARTED_FILE); attempt += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.STARTED_FILE)) throw new Error("first quota read did not start");

handlers["session_shutdown"]({ reason: "replace" }, { ui });
handlers["session_start"]({ reason: "replacement" }, { ui });
await new Promise((resolve) => setTimeout(resolve, 800));

const rendered = statuses.filter(([, text]) => text !== undefined).map(([, text]) => text);
if (rendered.includes("Claude 40% left · GPT n/a left")) {
  throw new Error("stale refresh restored status: " + JSON.stringify(statuses));
}
if (rendered.length !== 1 || rendered[0] !== "Claude 70% left · GPT n/a left") {
  throw new Error("replacement did not refresh immediately: " + JSON.stringify(statuses));
}
if (statuses[0][1] !== undefined) {
  throw new Error("shutdown did not clear status before replacement refresh: " + JSON.stringify(statuses));
}

handlers["session_shutdown"]({ reason: "quit" }, { ui });
console.log("ok");
EOF
  expect_code 0 $? "generation lifecycle: $(cat /tmp/fm-quota-footer-generation.out)"
  grep -q "^ok$" /tmp/fm-quota-footer-generation.out || fail "generation lifecycle did not confirm ok: $(cat /tmp/fm-quota-footer-generation.out)"
  pass "quota footer: stale reads stay cleared and replacement sessions refresh immediately"
}

test_extract_all_models_percent
test_format_quota_footer
test_refresh_and_shutdown_lifecycle
test_shutdown_during_refresh_and_replacement_start
