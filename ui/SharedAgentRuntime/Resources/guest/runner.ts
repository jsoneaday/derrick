const chunks: Uint8Array[] = [];
for await (const chunk of Bun.stdin.stream()) {
  chunks.push(chunk);
}
const raw = Buffer.concat(chunks).toString("utf8");
let invoke: { event?: unknown } = {};
try {
  invoke = raw ? JSON.parse(raw) : {};
} catch {
  console.error("invalid invoke JSON");
  process.exit(1);
}
const { pathToFileURL } = await import("url");
const mod: { handle?: (event: unknown) => unknown } = await import(
  pathToFileURL("/workspace/script.ts").href
);
if (typeof mod.handle !== "function") {
  console.error("script must export function handle");
  process.exit(1);
}
const origLog = console.log;
const origErr = console.error;
console.log = () => {};
console.error = (...a: unknown[]) => {
  origErr(...a);
};
let result: unknown;
try {
  result = await mod.handle(invoke.event ?? invoke);
} catch (e) {
  const err = e as { stack?: string };
  origErr(String(err && err.stack ? err.stack : e));
  process.exit(1);
} finally {
  console.log = origLog;
  console.error = origErr;
}
if (!Array.isArray(result)) {
  origErr("handle() must return a JSON array of envelope objects");
  process.exit(1);
}
process.stdout.write(JSON.stringify(result));
