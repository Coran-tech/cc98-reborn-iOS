#!/usr/bin/env node
"use strict";
// Dependency-free, allowlisted snapshot of the browser runtime. Never copies
// the repository, an extension background, credentials, or deployment zips.
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const ROOT = path.resolve(__dirname, "..");
const DEFAULT_OUTPUT = path.join(ROOT, "ios", "CC98RebornShell", "Resources", "Reborn");
const ADAPTER = "runtime/ios-adapter.js", MOBILE = "runtime/ios-mobile.css";
const FIXTURE = "fixtures/runtime-smoke.html";
const EXTENSIONS = new Set([".js", ".css", ".html", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".ico", ".woff", ".woff2", ".ttf", ".eot", ".txt"]);
const EXCLUDED = new Set(["src/background.js", "src/semantic-background.js", "src/semantic-client.js", "src/openid-webvpn-bridge.js", "src/watermark-bridge.js", "assets/semantic-lab.zip"]);
function resourcePath(value) {
  if (typeof value !== "string" || !value || value.startsWith("/") || /[\\%?#:\u0000-\u001f]/.test(value)
    || value.split("/").some(part => !part || part === "." || part === "..")) throw new Error(`Unsafe resource path: ${String(value)}`);
  return value;
}
function inputFor(resource) {
  resourcePath(resource);
  if (resource.startsWith("runtime/")) return "ios/" + resource;
  if (resource === FIXTURE) return "ios/Fixtures/runtime-smoke.html";
  if (resource === "licenses/CC98-Reborn.txt") return "LICENSE";
  return resource;
}
function within(root, filename) {
  const relative = path.relative(root, filename);
  return relative !== ".." && !relative.startsWith(".." + path.sep) && !path.isAbsolute(relative);
}
function fileAt(root, relative) {
  resourcePath(relative);
  const filename = path.resolve(root, ...relative.split("/"));
  if (!within(root, filename)) throw new Error(`Input escaped repository: ${relative}`);
  const real = fs.realpathSync(filename);
  if (!within(fs.realpathSync(root), real)) throw new Error(`Input symlink escaped repository: ${relative}`);
  if (real !== path.resolve(fs.realpathSync(root), ...relative.split("/"))) throw new Error(`Linked inputs are not packaged: ${relative}`);
  if (!fs.statSync(real).isFile()) throw new Error(`Not a regular input: ${relative}`);
  return real;
}
function allowed(resource) {
  return !EXCLUDED.has(resource) && /^(?:src\/|popup\/|images\/|assets\/|runtime\/|fixtures\/|licenses\/|experiments\/question-mark\/content\.)/.test(resource)
    && EXTENSIONS.has(path.posix.extname(resource).toLowerCase())
    && !/(?:^|\/)(?:\.runtime|\.git|node_modules|question-service|outputs|reference|credentials?)(?:\/|$)/i.test(resource)
    && !/(?:private[-_]?key|service[-_]?token|\.env)(?:\.|$)/i.test(resource);
}
function wildcard(pattern, value) {
  return new RegExp("^" + pattern.split("*").map(part => part.replace(/[|\\{}()[\]^$+?.]/g, "\\$&")).join(".*") + "$").test(value);
}
function applies(group) {
  const url = "https://www.cc98.org/topic/1";
  return (group.matches || []).some(pattern => wildcard(pattern, url))
    && !(group.exclude_matches || []).some(pattern => wildcard(pattern, url));
}
function unique(values) { return [...new Set(values)]; }
function resolveReference(parent, reference) {
  if (!reference || /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(reference)) return null;
  const raw = reference.split(/[?#]/)[0];
  if (!raw || /[\\%\u0000-\u001f]/.test(raw) || raw.startsWith("/")) throw new Error(`Unsafe relative asset in ${parent}`);
  return resourcePath(path.posix.normalize(path.posix.join(path.posix.dirname(parent), raw)));
}
function references(resource, text) {
  const found = [];
  const relative = candidate => { const result = resolveReference(resource, candidate); if (result) found.push(result); };
  if (resource.endsWith(".html")) {
    for (const match of text.matchAll(/(?:src|href)\s*=\s*["']([^"']+)["']/gi)) relative(match[1]);
  }
  if (resource.endsWith(".css")) {
    for (const match of text.matchAll(/url\(\s*(?:"([^"]+)"|'([^']+)'|([^\s)]+))\s*\)/gi)) relative(match[1] || match[2] || match[3]);
  }
  if (resource.endsWith(".js")) {
    for (const match of text.matchAll(/(?:new\s+Worker|importScripts)\(\s*["']([^"']+)["']/g)) relative(match[1]);
    for (const match of text.matchAll(/(?:chrome\.)?runtime\.getURL\(\s*["']([^"']+)["']/g)) found.push(resourcePath(match[1]));
  }
  return unique(found);
}
function expandPattern(root, pattern) {
  if (!pattern.includes("*")) return [resourcePath(pattern)];
  const parts = pattern.split("/");
  if (parts.slice(0, -1).some(part => part.includes("*")) || parts.at(-1) !== "*") throw new Error(`Unsupported manifest asset pattern: ${pattern}`);
  const prefix = resourcePath(parts.slice(0, -1).join("/"));
  const directory = path.resolve(root, prefix);
  if (!within(root, fs.realpathSync(directory))) throw new Error(`Asset directory escaped root: ${prefix}`);
  return fs.readdirSync(directory, { withFileTypes: true }).filter(entry => entry.isFile()).map(entry => prefix + "/" + entry.name).sort();
}
function collectPlan(root = ROOT) {
  root = path.resolve(root);
  const manifest = JSON.parse(fs.readFileSync(fileAt(root, "manifest.json"), "utf8"));
  if (!/^\d+(?:\.\d+){1,3}$/.test(manifest.version)) throw new Error("Invalid extension version");
  const groups = (manifest.content_scripts || []).filter(applies);
  const pageScripts = unique(groups.filter(group => group.world === "MAIN").flatMap(group => group.js || []));
  const contentScripts = [ADAPTER, ...unique(groups.filter(group => group.world !== "MAIN").flatMap(group => group.js || []))];
  const styles = [...unique(groups.flatMap(group => group.css || [])), MOBILE];
  const selected = new Set();
  const queue = [...pageScripts, ...contentScripts, ...styles, FIXTURE, "src/content-filter-worker.js",
    "licenses/CC98-Reborn.txt", "src/vendor/katex/LICENSE.txt", "src/vendor/showdown/LICENSE.txt"];
  for (const section of manifest.web_accessible_resources || []) for (const pattern of section.resources || []) queue.push(...expandPattern(root, pattern));
  queue.push(...Object.values(manifest.icons || {}));
  const excludedReferences = new Set();
  while (queue.length) {
    const resource = resourcePath(queue.shift());
    if (selected.has(resource)) continue;
    if (EXCLUDED.has(resource)) { excludedReferences.add(resource); continue; }
    if (!allowed(resource)) throw new Error(`Resource is not allowlisted: ${resource}`);
    const filename = fileAt(root, inputFor(resource));
    selected.add(resource);
    if (/\.(?:js|css|html)$/.test(resource)) queue.push(...references(resource, fs.readFileSync(filename, "utf8")));
  }
  for (const filename of [...pageScripts, ...contentScripts, ...styles]) if (!selected.has(filename)) throw new Error(`Required runtime was excluded: ${filename}`);
  const all = [...selected].sort();
  // assets is the complete scheme-handler allowlist, including executable lists.
  const index = { schemaVersion: 1, extensionVersion: manifest.version, pageScripts, contentScripts, styles, assets: all };
  // Scripts stay separate global scripts: do not wrap each source in a function.
  new vm.Script(pageScripts.map(item => fs.readFileSync(fileAt(root, inputFor(item)), "utf8")).join("\n;\n"));
  new vm.Script(contentScripts.map(item => fs.readFileSync(fileAt(root, inputFor(item)), "utf8")).join("\n;\n"));
  return { root, index, resources: all, inputs: unique(["manifest.json", ...all.map(inputFor)]).sort(), excludedReferences: [...excludedReferences].sort() };
}
function collectInputs(root = ROOT) { return collectPlan(root).inputs; }
function rewriteCSS(resource, source) {
  return source.replace(/url\(\s*(?:"([^"]+)"|'([^']+)'|([^\s)]+))\s*\)/gi, (original, one, two, three) => {
    const reference = one || two || three;
    const target = resolveReference(resource, reference);
    if (!target) return original;
    const suffix = reference.slice(reference.split(/[?#]/)[0].length);
    return `url("reborn-asset://bundle/${target}${suffix}")`;
  });
}
function assertOutput(root, output) {
  const resolved = path.resolve(output);
  if (resolved === path.parse(resolved).root || resolved === root || within(resolved, root)) throw new Error("Output must not contain the source repository");
  // A fixed build directory or explicitly supplied dedicated empty directory.
  if (fs.existsSync(resolved)) {
    if (fs.lstatSync(resolved).isSymbolicLink()) throw new Error("Output must not be a symlink");
    const entries = fs.readdirSync(resolved);
    if (entries.length && !fs.existsSync(path.join(resolved, "manifest-index.json"))) throw new Error("Output is not a managed Reborn resource directory");
  }
  let parent = path.dirname(resolved);
  while (!fs.existsSync(parent)) parent = path.dirname(parent);
  if (fs.realpathSync(parent) !== parent) throw new Error("Output ancestor must not be a symlink");
  return resolved;
}
function packageResources({ root = ROOT, output = DEFAULT_OUTPUT } = {}) {
  const plan = collectPlan(root);
  const destination = assertOutput(plan.root, output);
  if (fs.existsSync(destination)) {
    // Resolved, dedicated path checked immediately above. Never touch source.
    fs.rmSync(destination, { recursive: true });
  }
  fs.mkdirSync(destination, { recursive: true });
  for (const resource of plan.resources) {
    const filename = fileAt(plan.root, inputFor(resource));
    let data = fs.readFileSync(filename);
    if (resource.endsWith(".css")) data = Buffer.from(rewriteCSS(resource, data.toString("utf8")));
    if (resource === ADAPTER) data = Buffer.from(data.toString("utf8").replace('"__CC98_IOS_EXTENSION_VERSION__"', JSON.stringify(plan.index.extensionVersion)));
    const target = path.join(destination, ...resource.split("/"));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, data);
  }
  fs.writeFileSync(path.join(destination, "manifest-index.json"), JSON.stringify(plan.index, null, 2) + "\n");
  return { ...plan, output: destination };
}
if (require.main === module) {
  try {
    const args = process.argv.slice(2);
    if (args[0] === "--list-inputs" && args.length === 1) console.log(JSON.stringify(collectInputs(), null, 2));
    else {
      if (args.length && !(args.length === 2 && args[0] === "--output")) throw new Error("Usage: node scripts/package-ios-resources.cjs [--output dedicated-directory | --list-inputs]");
      const result = packageResources({ output: args.length ? args[1] : DEFAULT_OUTPUT });
      console.log(JSON.stringify({ output: result.output, extensionVersion: result.index.extensionVersion, files: result.resources.length, excludedReferences: result.excludedReferences }, null, 2));
    }
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
module.exports = { collectPlan, collectInputs, packageResources, resourcePath, resolveReference, rewriteCSS, DEFAULT_OUTPUT };
