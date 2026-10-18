// Bundles the JavaScript helpers into self-contained files under Vendor/build/js.
import { build } from "esbuild";
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "..", "Vendor", "build", "js");
mkdirSync(out, { recursive: true });

const common = { bundle: true, format: "iife", minify: true, legalComments: "external", logLevel: "info", charset: "utf8" };

// JavaScriptCore: ES2020 is safe on macOS 13's JSC; BigInt is required by cupertino-files.
await build({ ...common, entryPoints: [path.join(here, "src/pages-bridge.js")], outfile: path.join(out, "pages-bridge.js"), target: "safari16", platform: "neutral", mainFields: ["module", "main"] });
await build({ ...common, entryPoints: [path.join(here, "src/docx-render.js")], outfile: path.join(out, "docx-render.js"), target: "safari16", platform: "browser" });
