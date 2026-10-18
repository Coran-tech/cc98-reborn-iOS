"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const pack = require("../scripts/package-ios-resources.cjs");
const root = path.resolve(__dirname, "..");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"));
const plan = pack.collectPlan(root);
test("ordered manifest extraction preserves the complete applicable scripts and global scope", () => {
  assert.equal(plan.index.schemaVersion, 1);
  assert.equal(plan.index.extensionVersion, manifest.version);
  assert.deepEqual(plan.index.pageScripts, ["src/page-submit-monitor.js"]);
  assert.equal(plan.index.contentScripts[0], "runtime/ios-adapter.js");
  assert.deepEqual(plan.index.contentScripts.slice(1), ["src/topic-drawer.js", ...manifest.content_scripts.at(-1).js]);
  assert.equal(plan.index.styles.at(-1), "runtime/ios-mobile.css");
  assert.equal(plan.resources.includes("src/openid-webvpn-bridge.js"), false);
});
test("closure includes popup, independent regex worker, CSS fonts, emotions and licenses", () => {
  for (const filename of ["popup/popup.html", "popup/popup.js", "popup/settings-backup.js", "popup/semantic-settings.html", "popup/semantic-settings.js", "src/settings-backup-core.js", "src/content-filter-frame.html", "src/content-filter-frame.js", "src/content-filter-worker.js", "src/content-filter-core.js", "src/vendor/katex/LICENSE.txt", "src/vendor/showdown/LICENSE.txt", "licenses/CC98-Reborn.txt", "fixtures/runtime-smoke.html"]) assert.ok(plan.resources.includes(filename), filename);
  assert.ok(plan.resources.some(item => item.startsWith("src/vendor/katex/fonts/") && item.endsWith(".woff2")));
  assert.ok(plan.resources.some(item => item.startsWith("images/mahjong/")));
  assert.ok(plan.resources.includes("images/avatar/avatar.jpg"));
});
test("only the required source snapshot is listed, never credentials or extension background", () => {
  assert.deepEqual(pack.collectInputs(root), plan.inputs);
  assert.ok(plan.inputs.includes("manifest.json"));
  assert.ok(plan.inputs.includes("ios/runtime/ios-adapter.js"));
  assert.ok(plan.inputs.includes("ios/Fixtures/runtime-smoke.html"));
  for (const input of plan.inputs) assert.doesNotMatch(input, /(?:^|\/)(?:question-service|outputs|reference|\.runtime|\.git|node_modules)(?:\/|$)|background\.js$|semantic-lab\.zip$|service-token/i);
  assert.ok(plan.excludedReferences.includes("assets/semantic-lab.zip"));
});
test("resource paths and normalized references cannot escape the bundle", () => {
  for (const value of ["../private", "a/../../private", "/etc/passwd", "C:/private", "a\\b", "%2e%2e/private", "a?secret", "a//b"]) assert.throws(() => pack.resourcePath(value));
  assert.throws(() => pack.resolveReference("src/a.css", "../../private"));
  assert.equal(pack.resolveReference("popup/popup.html", "../src/theme-core.js"), "src/theme-core.js");
  assert.equal(pack.resolveReference("src/a.css", "https://example.invalid/a.png"), null);
});
test("CSS relative URLs become scheme URLs while data and external URLs remain unchanged", () => {
  const value = pack.rewriteCSS("src/vendor/katex/katex.min.css", 'a{src:url(fonts/font.woff2)}b{background:url("data:image/svg+xml,x")}c{src:url(https://example.invalid/x)}');
  assert.match(value, /reborn-asset:\/\/bundle\/src\/vendor\/katex\/fonts\/font.woff2/);
  assert.match(value, /data:image\/svg\+xml,x/);
  assert.match(value, /https:\/\/example.invalid\/x/);
});
test("written package inventory exists and all actual JavaScript parses", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "cc98-ios-resources-"));
  try {
    const result = pack.packageResources({ root, output: temporary });
    const index = JSON.parse(fs.readFileSync(path.join(temporary, "manifest-index.json"), "utf8"));
    assert.deepEqual(index, result.index);
    for (const filename of new Set([...index.pageScripts, ...index.contentScripts, ...index.styles, ...index.assets])) {
      const full = path.join(temporary, filename);
      assert.ok(fs.statSync(full).isFile(), filename);
      if (filename.endsWith(".js")) assert.doesNotThrow(() => new vm.Script(fs.readFileSync(full, "utf8"), { filename }));
    }
    for (const scripts of [index.contentScripts, index.pageScripts]) new vm.Script(scripts.map(filename => fs.readFileSync(path.join(temporary, filename), "utf8")).join("\n;\n"));
    assert.equal(fs.existsSync(path.join(temporary, "manifest.json")), false);
    const adapter = fs.readFileSync(path.join(temporary, "runtime/ios-adapter.js"), "utf8");
    assert.ok(adapter.includes(JSON.stringify(manifest.version))); assert.equal(adapter.includes("__CC98_IOS_EXTENSION_VERSION__"), false);
    assert.match(fs.readFileSync(path.join(temporary, "src/content-filter-frame.js"), "utf8"), /new Worker\("content-filter-worker.js"\)/);
    assert.match(fs.readFileSync(path.join(temporary, "src/content-filter-worker.js"), "utf8"), /importScripts\("content-filter-core.js"\)/);
    const content = fs.readFileSync(path.join(temporary, "src/content.js"), "utf8");
    assert.equal(content, fs.readFileSync(path.join(root, "src/content.js"), "utf8"));
    assert.match(content, /maybeShowOpenIdBindPromptAfterLogin/);
    // Repackage the dedicated managed output; stale generated artifacts disappear.
    fs.writeFileSync(path.join(temporary, "stale.txt"), "obsolete");
    pack.packageResources({ root, output: temporary });
    assert.equal(fs.existsSync(path.join(temporary, "stale.txt")), false);
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
});
test("packager refuses repository roots and unrelated nonempty output directories", () => {
  assert.throws(() => pack.packageResources({ root, output: root }), /Output/);
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "cc98-ios-unmanaged-"));
  try { fs.writeFileSync(path.join(temporary, "keep.txt"), "user data"); assert.throws(() => pack.packageResources({ root, output: temporary }), /managed/); assert.equal(fs.readFileSync(path.join(temporary, "keep.txt"), "utf8"), "user data"); }
  finally { fs.rmSync(temporary, { recursive: true, force: true }); }
});
