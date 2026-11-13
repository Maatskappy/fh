// loops `runtime: "node"` shim: node --input-type=module -e <this file> -- <package root> <entry>
// Input JSON arrives on stdin, exactly one JSON output leaves on stdout, diagnostics go to stderr.
// Exit 0 is a result (a domain verdict included); any failure of the step is exit 1.
import { realpathSync } from "node:fs";
import * as nodeModule from "node:module";
import { join, sep } from "node:path";
import { pathToFileURL } from "node:url";

const [rootArgument, entry] = process.argv.slice(1);
const emit = process.stdout.write.bind(process.stdout);
// A module called in process can log freely, so here its console output joins the diagnostics
// and stdout carries the result alone.
process.stdout.write = process.stderr.write.bind(process.stderr);

// JSON.stringify would quietly turn these into null, drop them or rewrite them (a Date, a Map,
// a class instance); the step's output must be exactly what the function returned.
function strictJson(key, value) {
  const raw = this[key];
  const name = key || "output";
  if (typeof value === "number" && !Number.isFinite(value)) throw new Error(`${name} is ${value}, which JSON cannot represent`);
  if (value === undefined || typeof value === "function" || typeof value === "symbol") throw new Error(`${name} is ${typeof value}, which JSON cannot represent`);
  if (typeof raw === "object" && raw !== null && !Array.isArray(raw)) {
    const proto = Object.getPrototypeOf(raw);
    if ((proto !== Object.prototype && proto !== null) || typeof raw.toJSON === "function") throw new Error(`${name} is a ${proto?.constructor?.name ?? "non-plain object"}, not plain JSON`);
  }
  return value;
}

try {
  if (typeof nodeModule.registerHooks !== "function") throw new Error("this Node has no module.registerHooks; the node runtime needs Node 22.15 or later (23.5 or later on 23)");
  const root = realpathSync(rootArgument);
  const packageUrl = pathToFileURL(root + sep).href;
  // A contract check on imports, not a sandbox. loops/0.3 says a node step imports package-local
  // files and Node's built-in modules only, and this reports an import that breaks that rule. It
  // contains nothing: built-ins such as node:fs and node:child_process are allowed. The
  // container this process runs in is the security boundary.
  nodeModule.registerHooks({
    resolve(specifier, context, nextResolve) {
      const resolved = nextResolve(specifier, context);
      if (resolved.url.startsWith("node:") || resolved.url.startsWith(packageUrl)) return resolved;
      throw new Error(`import "${specifier}" is outside the package; a node step may import only package-local files and Node's built-in modules`);
    },
  });
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  const loaded = await import(pathToFileURL(join(root, entry)).href);
  if (typeof loaded.default !== "function") throw new Error("no default export function");
  const text = JSON.stringify(await loaded.default(input), strictJson);
  emit(`${text}\n`, () => process.exit(0));
} catch (error) {
  process.stderr.write(`${entry}: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}\n`, () => process.exit(1));
}
