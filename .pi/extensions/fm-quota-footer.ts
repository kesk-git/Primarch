// Firstmate Pi footer: Claude and GPT subscription remaining percentages.
//
// Reads `quota-axi --json` asynchronously and appends "Claude <n>% left · GPT
// <n>% left" to the footer via ctx.ui.setStatus, alongside Pi's built-in
// footer. Refreshes at session start and every five minutes; one in-flight
// guard prevents concurrent reads. A failed read or missing row shows "n/a"
// for that provider.
import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "firstmate-quota-footer";
const REFRESH_INTERVAL_MS = 5 * 60 * 1000;
const READ_TIMEOUT_MS = 5000;

export type QuotaPercents = {
  claude: number | undefined;
  codex: number | undefined;
};

export function extractAllModelsPercent(json: string, provider: string): number | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return undefined;
  }
  if (typeof parsed !== "object" || parsed === null) return undefined;
  const providers = (parsed as { providers?: unknown }).providers;
  if (!Array.isArray(providers)) return undefined;
  const row = providers.find(
    (p) => typeof p === "object" && p !== null && (p as { provider?: unknown }).provider === provider,
  );
  if (!row) return undefined;
  const availability = (row as { quotaSemantics?: { effectiveAvailability?: unknown } }).quotaSemantics
    ?.effectiveAvailability;
  if (!Array.isArray(availability)) return undefined;
  const allModels = availability.find(
    (a) => typeof a === "object" && a !== null && (a as { scope?: unknown }).scope === "all_models",
  );
  if (!allModels) return undefined;
  const percent = (allModels as { effectivePercentRemaining?: unknown }).effectivePercentRemaining;
  return typeof percent === "number" ? percent : undefined;
}

export function formatQuotaFooter(percents: QuotaPercents): string {
  const claude = percents.claude === undefined ? "n/a" : `${Math.round(percents.claude)}%`;
  const gpt = percents.codex === undefined ? "n/a" : `${Math.round(percents.codex)}%`;
  return `Claude ${claude} left · GPT ${gpt} left`;
}

function readQuota(): Promise<QuotaPercents> {
  return new Promise((finish) => {
    const failed: QuotaPercents = { claude: undefined, codex: undefined };
    let child;
    try {
      child = spawn("quota-axi", ["--json"], { stdio: ["ignore", "pipe", "ignore"] });
    } catch {
      finish(failed);
      return;
    }
    let stdout = "";
    let settled = false;
    const done = (result: QuotaPercents) => {
      if (settled) return;
      settled = true;
      finish(result);
    };
    const timer = setTimeout(() => {
      child.kill();
      done(failed);
    }, READ_TIMEOUT_MS);
    child.stdout?.on("data", (chunk) => {
      stdout += chunk;
    });
    child.on("error", () => {
      clearTimeout(timer);
      done(failed);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        done(failed);
        return;
      }
      done({
        claude: extractAllModelsPercent(stdout, "claude"),
        codex: extractAllModelsPercent(stdout, "codex"),
      });
    });
  });
}

export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setInterval> | undefined;
  let inFlight = false;
  let generation = 0;

  const refresh = async (ui: ExtensionUIContext): Promise<void> => {
    if (inFlight) return;
    const refreshGeneration = generation;
    inFlight = true;
    try {
      const percents = await readQuota();
      if (refreshGeneration === generation) {
        ui.setStatus(STATUS_KEY, formatQuotaFooter(percents));
      }
    } finally {
      if (refreshGeneration === generation) {
        inFlight = false;
      }
    }
  };

  pi.on("session_start", (_event, ctx) => {
    generation += 1;
    inFlight = false;
    void refresh(ctx.ui);
    if (timer) clearInterval(timer);
    timer = setInterval(() => {
      void refresh(ctx.ui);
    }, REFRESH_INTERVAL_MS);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    generation += 1;
    inFlight = false;
    if (timer) {
      clearInterval(timer);
      timer = undefined;
    }
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });
}
