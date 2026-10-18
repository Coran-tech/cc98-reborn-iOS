"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "../ios/runtime/ios-adapter.js"), "utf8");
function boot(handler, globals = {}) {
  const calls = [], events = {};
  const context = vm.createContext({ setTimeout, clearTimeout,
    addEventListener(name, fn) { events[name] = fn; },
    webkit: handler === null ? undefined : { messageHandlers: { reborn: { postMessage(packet) {
      calls.push(JSON.parse(JSON.stringify(packet)));
      if (packet.command === "diagnostics.report") return Promise.resolve({ ok: true, value: null });
      return Promise.resolve(handler ? handler(packet) : { ok: true, value: {} });
    } } } }, ...globals
  });
  vm.runInContext(source.replace('"__CC98_IOS_EXTENSION_VERSION__"', '"0.4.1"'), context);
  return { context, chrome: context.chrome, api: context.__CC98IOS__, calls, events };
}
const json = value => JSON.parse(JSON.stringify(value));
test("getURL/getManifest are local, sanitized, and do not expose extension manifest credentials", () => {
  const { chrome } = boot();
  assert.equal(chrome.runtime.getURL("src/content.js"), "reborn-asset://bundle/src/content.js");
  assert.equal(chrome.runtime.getURL(""), "reborn-asset://bundle/");
  assert.deepEqual(json(chrome.runtime.getManifest()), { manifest_version: 3, name: "CC98 Reborn", version: "0.4.1" });
  for (const value of ["../a", "/etc", "a/../b", "a\\b", "https://evil/", "%2e%2e/a", "a?token=x"]) assert.throws(() => chrome.runtime.getURL(value), { code: "INVALID_RESOURCE_PATH" });
});
test("storage.get supports null, string, array, defaults and callback without returning denied records", async () => {
  const { chrome, calls } = boot(() => ({ ok: true, value: { cc98ComfortSettings: { enabled: true }, token: "not-returned" } }));
  assert.deepEqual(json(await chrome.storage.local.get(null)), { cc98ComfortSettings: { enabled: true } });
  await chrome.storage.local.get("cc98ComfortSettings");
  await chrome.storage.local.get(["cc98ComfortSettings"]);
  assert.deepEqual(json(await chrome.storage.local.get({ "cc98RebornPinnedBoards:v1": [] }))["cc98RebornPinnedBoards:v1"], []);
  await new Promise(resolve => { const returned = chrome.storage.local.get("cc98ComfortSettings", value => { assert.equal(value.cc98ComfortSettings.enabled, true); assert.equal(chrome.runtime.lastError, undefined); resolve(); }); assert.equal(returned, undefined); });
  assert.equal(calls.filter(call => call.command === "storage.get").length, 5);
});
test("storage changes preserve value semantics and emit local onChanged once", async () => {
  const { chrome, api } = boot(() => ({ ok: true, value: { changes: { cc98ComfortSettings: { oldValue: { enabled: true }, newValue: { enabled: false } } } } }));
  const seen = [];
  const listener = (...args) => seen.push(json(args));
  chrome.storage.onChanged.addListener(listener);
  await chrome.storage.local.set({ cc98ComfortSettings: { enabled: false, aiSearchSuggestApiKey: "" } });
  assert.equal(seen.length, 1); assert.equal(seen[0][1], "local");
  assert.equal(seen[0][0].cc98ComfortSettings.newValue.enabled, false);
  chrome.storage.onChanged.removeListener(listener);
  api.receiveStorageChanges({ cc98ComfortSettings: { newValue: {} } }, "local");
  assert.equal(seen.length, 1);
});
test("ordinary storage cannot manufacture binding, overwrite credentials, or use prototype keys", async () => {
  const { chrome, calls } = boot();
  for (const key of ["cc98RebornOpenIdBinding:v1", "cc98RebornSemanticConnection:v1", "accessToken", "__proto__"]) {
    await assert.rejects(chrome.storage.local.set({ [key]: { bound: true } }), { code: "STORAGE_KEY_DENIED" });
  }
  await assert.rejects(chrome.storage.local.remove("cc98RebornOpenIdBinding:v1"), { code: "STORAGE_KEY_DENIED" });
  await assert.rejects(chrome.storage.local.get({ "cc98RebornOpenIdBinding:v1": { bound: true } }), { code: "STORAGE_KEY_DENIED" });
  await assert.rejects(chrome.storage.local.set({ cc98ComfortSettings: { aiSearchSuggestApiKey: "test-placeholder" } }), { code: "CREDENTIAL_STORAGE_DENIED" });
  await assert.rejects(chrome.storage.local.get("password"), { code: "STORAGE_KEY_DENIED" });
  assert.equal(calls.some(call => call.command === "storage.set" || call.command === "storage.remove"), false);
});
test("callback lastError is scoped to callback while Promise errors reject", async () => {
  const { chrome } = boot(() => ({ ok: false, error: { code: "DENIED", message: "拒绝" } }));
  await new Promise(resolve => chrome.storage.local.get("cc98ComfortSettings", value => { assert.equal(value, undefined); assert.equal(chrome.runtime.lastError.code, "DENIED"); resolve(); }));
  assert.equal(chrome.runtime.lastError, undefined);
  await assert.rejects(chrome.storage.local.get("cc98ComfortSettings"), { code: "DENIED" });
});
test("unconfigured OAuth returns a readable failure, never a fake binding or identity", async () => {
  const { chrome } = boot(({ args }) => args.message.type === "CC98_REBORN_OPENID_GET_STATE"
    ? { ok: true, value: { ok: true, configured: false, binding: null } }
    : { ok: false, error: { code: "NOT_CONFIGURED", message: "iOS OpenID 尚未配置" } });
  const state = await chrome.runtime.sendMessage({ type: "CC98_REBORN_OPENID_GET_STATE" });
  assert.equal(state.binding, null); assert.equal(state.configured, false);
  await new Promise(resolve => chrome.runtime.sendMessage({ type: "CC98_REBORN_OPENID_LOGIN" }, result => { assert.equal(result.ok, false); assert.equal(result.code, "NOT_CONFIGURED"); assert.match(result.error, /尚未配置/); assert.equal(chrome.runtime.lastError, undefined); resolve(); }));
});
test("unsupported background APIs and messages do not pretend success", async () => {
  const { chrome } = boot(() => ({ ok: false, error: { code: "UNSUPPORTED", message: "未接入" } }));
  assert.equal((await chrome.runtime.sendMessage({ type: "CC98_REBORN_INIT_TOPIC_DRAWER" })).ok, false);
  assert.equal((await chrome.runtime.sendMessage({ type: "ARBITRARY_FETCH", url: "https://invalid.example" })).code, "UNSUPPORTED");
  await assert.rejects(chrome.downloads.download({}), { code: "UNSUPPORTED" });
  await assert.rejects(chrome.permissions.request({}), { code: "UNSUPPORTED" });
  await assert.rejects(chrome.storage.local.clear(), { code: "UNSUPPORTED" });
});
test("native messages reach the existing onMessage receiver, unsupported messages cannot invoke it", async () => {
  const { chrome, api } = boot();
  let invoked = 0;
  chrome.runtime.onMessage.addListener((message, _sender, reply) => { invoked++; reply({ ok: true, account: null }); });
  assert.equal((await api.dispatchMessage({ type: "CC98_REBORN_GET_CURRENT_WEB_ACCOUNT" })).account, null);
  assert.equal((await api.dispatchMessage({ type: "READ_ALL_TOKENS" })).ok, false);
  assert.equal(invoked, 1);
});
test("diagnostics expose categories, never blocked URL or exception content", async () => {
  const { api, calls, events } = boot();
  api.report("csp-blocked", { code: "CSP_BLOCKED", url: "https://example.invalid?token=placeholder", resource: "a?code=placeholder" });
  events.securitypolicyviolation({ effectiveDirective: "frame-src", blockedURI: "https://example.invalid?token=placeholder" });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(JSON.stringify(calls).includes("placeholder"), false);
});
test("missing bridge fails instead of using page localStorage or fake in-memory persistence", async () => {
  const { chrome } = boot(null);
  await assert.rejects(chrome.storage.local.get(null), { code: "BRIDGE_UNAVAILABLE" });
  assert.doesNotMatch(source, /localStorage|fetch\(|XMLHttpRequest/);
});
test("unsupported embedded settings show a visible notice without faking a frame handshake", () => {
  let observe;
  const inserted = [];
  const frame = { name: "", matches: selector => selector === "iframe", getAttribute: () => "reborn-asset://bundle/popup/popup.html", parentNode: { insertBefore: note => inserted.push(note) } };
  boot(null, { document: { createElement: () => ({ setAttribute() {} }) }, MutationObserver: class { constructor(fn) { observe = fn; } observe() {} } });
  observe([{ addedNodes: [frame] }]);
  assert.equal(inserted.length, 1);
  assert.match(inserted[0].textContent, /尚未接入/);
  observe([{ addedNodes: [frame] }]);
  assert.equal(inserted.length, 1);
});
