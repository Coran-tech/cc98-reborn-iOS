/* Minimal Chrome content-script compatibility for the iOS verification shell.
 * This runs in cc98.reborn.v1, never the website's page world. */
(() => {
  "use strict";
  if (globalThis.__CC98IOS__) return;
  const extensionVersion = "__CC98_IOS_EXTENSION_VERSION__";
  const base = "reborn-asset://bundle/";
  const readOnlyKeys = new Set(["cc98RebornOpenIdBinding:v1", "cc98RebornSemanticConnection:v1", "cc98RebornSemanticState:v1"]);
  const ordinaryKeys = new Set(["cc98ComfortSettings", "cc98RebornPinnedBoards:v1", "cc98RebornExtendedUbbTour:v1"]);
  const scopedKeys = [
    /^cc98Reborn(?:ReadLater:v1|SearchHistory:v1):uid:(?:guest|[1-9]\d*)$/,
    /^cc98RebornUserNote:uid:[1-9]\d*:user:[1-9]\d*$/,
    /^cc98RebornPrivateMessagePins:v1:uid:[1-9]\d*$/
  ];
  const messageTypes = new Set([
    "CC98_REBORN_OPENID_GET_STATE", "CC98_REBORN_OPENID_LOGIN", "CC98_REBORN_OPENID_LOGOUT",
    "CC98_REBORN_FIND_CURRENT_WEB_ACCOUNT", "CC98_REBORN_EXIT_CURRENT_WEB_ACCOUNT",
    "CC98_REBORN_CLEAR_CC98_SITE_DATA", "CC98_REBORN_INIT_TOPIC_DRAWER", "CC98_REBORN_DOWNLOAD_FILE",
    "CC98_REBORN_GET_UPDATE_STATUS", "CC98_REBORN_CHECK_UPDATE", "CC98_REBORN_OPEN_RELEASES",
    "CC98_REBORN_CONSUME_STARTUP_UPDATE_NOTICE", "CC98_REBORN_QUESTION_GET",
    "CC98_REBORN_QUESTION_ACCEPT_PRIVACY", "CC98_REBORN_QUESTION_TOGGLE",
    "CC98_SEMANTIC_STATUS", "CC98_SEMANTIC_CONNECT", "CC98_SEMANTIC_DISCONNECT",
    "CC98_SEMANTIC_ANALYZE", "CC98_SEMANTIC_CANCEL", "CC98_SEMANTIC_TEST"
  ]);
  function failure(code, message) { return Object.assign(new Error(message), { code }); }
  function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
  function event() {
    const listeners = new Set();
    return { addListener(fn) { if (typeof fn === "function") listeners.add(fn); }, removeListener(fn) { listeners.delete(fn); },
      hasListener(fn) { return listeners.has(fn); }, hasListeners() { return listeners.size > 0; },
      emit(...args) { for (const fn of [...listeners]) { try { fn(...args); } catch { report("runtime.error", { code: "LISTENER_ERROR" }); } } },
      listeners };
  }
  const changes = event(), incoming = event();
  let lastError;
  function call(command, args) {
    const handler = globalThis.webkit?.messageHandlers?.reborn;
    if (!handler || typeof handler.postMessage !== "function") return Promise.reject(failure("BRIDGE_UNAVAILABLE", "iOS 原生桥不可用，请返回原站模式"));
    return Promise.resolve().then(() => handler.postMessage({ command, args })).then(reply => {
      if (!object(reply) || typeof reply.ok !== "boolean") throw failure("INVALID_RESPONSE", "iOS 原生桥响应格式错误");
      if (!reply.ok) throw failure(reply.error?.code || "NATIVE_ERROR", reply.error?.message || "iOS 原生操作失败");
      return reply.value;
    });
  }
  function report(name, details = {}) {
    // Do not forward URLs, text, accounts, OAuth parameters, or exceptions.
    const safe = {};
    for (const key of ["code", "command", "resource", "directive"]) {
      if (typeof details[key] === "string" && /^[a-zA-Z0-9_./:-]{1,160}$/.test(details[key])) safe[key] = details[key];
    }
    for (const key of ["line", "column"]) if (Number.isSafeInteger(details[key]) && details[key] >= 0) safe[key] = details[key];
    call("diagnostics.report", { event: name, details: safe }).catch(() => {});
  }
  function dual(promise, callback) {
    if (typeof callback !== "function") return promise;
    promise.then(value => callback(value), error => {
      lastError = { message: error.message, code: error.code };
      try { callback(undefined); } finally { lastError = undefined; }
    });
    return undefined;
  }
  function keyAllowed(key, write = false) {
    return typeof key === "string" && key.length <= 180
      && (ordinaryKeys.has(key) || scopedKeys.some(pattern => pattern.test(key)) || (!write && readOnlyKeys.has(key)));
  }
  function keysOf(keys, write) {
    if (keys == null && !write) return [];
    const names = typeof keys === "string" ? [keys] : Array.isArray(keys) ? keys : !write && object(keys) ? Object.keys(keys) : null;
    if (!names || names.length > 500 || names.some(key => !keyAllowed(key, write))) throw failure("STORAGE_KEY_DENIED", "该存储键不在 iOS 允许列表中，或一次操作超过 500 个键");
    return names;
  }
  function noSecrets(value, depth = 0) {
    if (depth > 20) throw failure("INVALID_ARGUMENT", "设置嵌套过深");
    if (!value || typeof value !== "object") return;
    for (const [key, child] of Object.entries(value)) {
      if (["__proto__", "prototype", "constructor"].includes(key)) throw failure("INVALID_ARGUMENT", "设置字段无效");
      if (/(?:token|secret|password|credential|api.?key)/i.test(key) && child !== "" && child !== null) throw failure("CREDENTIAL_STORAGE_DENIED", "验证壳不保存服务凭据");
      noSecrets(child, depth + 1);
    }
  }
  function storageGet(keys, callback) {
    if (typeof keys === "function") { callback = keys; keys = null; }
    return dual(Promise.resolve().then(() => {
      keysOf(keys, false);
      if (object(keys) && Object.entries(keys).some(([key, value]) => readOnlyKeys.has(key) && value !== null)) throw failure("STORAGE_KEY_DENIED", "认证状态不能由调用者默认值生成");
      return call("storage.get", { keys: keys ?? null });
    })
      .then(records => {
        if (!object(records)) throw failure("INVALID_RESPONSE", "存储响应不是对象");
        const safe = {};
        for (const [key, value] of Object.entries(records)) if (keyAllowed(key, false)) safe[key] = value;
        if (object(keys)) for (const [key, value] of Object.entries(keys)) if (!Object.hasOwn(safe, key)) safe[key] = value;
        return safe;
      }).catch(error => { report("storage.error", { command: "storage.get", code: error.code || "STORAGE_ERROR" }); throw error; }), callback);
  }
  function storageMutation(method, args, callback) {
    return dual(Promise.resolve().then(() => {
      if (method === "set") {
        if (!object(args)) throw failure("INVALID_ARGUMENT", "设置必须是对象");
        keysOf(Object.keys(args), true); noSecrets(args);
        if (JSON.stringify(args).length > 2 * 1024 * 1024) throw failure("QUOTA_EXCEEDED", "一次设置写入超过 2 MiB 限制");
      } else keysOf(args, true);
      return call(`storage.${method}`, method === "set" ? { values: args } : { keys: args });
    }).then(value => {
      if (!object(value?.changes)) throw failure("INVALID_RESPONSE", "存储写入没有返回变更结果");
      receiveStorageChanges(value.changes, "local");
    }).catch(error => { report("storage.error", { command: `storage.${method}`, code: error.code || "STORAGE_ERROR" }); throw error; }), callback);
  }
  function receiveStorageChanges(records, area = "local") {
    if (area !== "local" || !object(records)) return;
    const allowed = {};
    for (const [key, value] of Object.entries(records)) if (keyAllowed(key) && object(value)) allowed[key] = value;
    if (Object.keys(allowed).length) changes.emit(allowed, "local");
  }
  function unsupported(name, callback) {
    report("bridge.unsupported", { command: name, code: "UNSUPPORTED" });
    return dual(Promise.reject(failure("UNSUPPORTED", `iOS 验证壳尚未接入 ${name}`)), callback);
  }
  function sendMessage(message, callback) {
    const pending = Promise.resolve().then(() => {
      if (!object(message) || !messageTypes.has(message.type)) throw failure("UNSUPPORTED", "iOS 验证壳不支持此扩展消息");
      return call("runtime.message", { message });
    }).catch(error => {
      if (["UNSUPPORTED", "NOT_CONFIGURED", "AUTH_NOT_CONFIGURED"].includes(error.code)) {
        report("bridge.unsupported", { command: message?.type || "runtime.message", code: error.code });
        return { ok: false, error: error.message, code: error.code };
      }
      throw error;
    });
    return dual(pending, callback);
  }
  function getURL(path = "") {
    if (typeof path !== "string" || /[\\%?#\u0000-\u001f]/.test(path) || path.startsWith("/") || path.includes(":")
      || path.split("/").some(part => part === "." || part === "..")) throw failure("INVALID_RESOURCE_PATH", "包内资源路径无效");
    return base + path;
  }
  function dispatchMessage(message) {
    if (!["CC98_COMFORT_GET_STATE", "CC98_REBORN_GET_CURRENT_WEB_ACCOUNT", "CC98_REBORN_GET_BLACKLIST_PAGE_HREF", "CC98_REBORN_EXIT_CURRENT_ACCOUNT"].includes(message?.type)) return Promise.resolve({ ok: false, error: "UNSUPPORTED" });
    return new Promise(resolve => {
      let answered = false;
      const timer = setTimeout(() => { if (!answered) resolve({ ok: false, error: "NO_RECEIVER" }); }, 2000);
      const reply = value => { if (!answered) { answered = true; clearTimeout(timer); resolve(value); } };
      for (const listener of incoming.listeners) { try { listener(message, { id: "ios-native" }, reply); } catch { reply({ ok: false, error: "RECEIVER_FAILED" }); } }
    });
  }
  const chrome = {
    runtime: { get lastError() { return lastError; }, sendMessage, getURL,
      getManifest() { return { manifest_version: 3, name: "CC98 Reborn", version: extensionVersion }; }, onMessage: incoming },
    storage: { local: { get: storageGet, set: (values, cb) => storageMutation("set", values, cb), remove: (keys, cb) => storageMutation("remove", keys, cb), clear: cb => unsupported("storage.clear", cb) }, onChanged: changes },
    tabs: { query: (_args, cb) => unsupported("tabs.query", cb), sendMessage: (_id, _message, cb) => unsupported("tabs.sendMessage", cb),
      create: (args, cb) => dual(call("host.open", { url: args?.url, target: "_blank" }), cb) },
    downloads: { download: (_args, cb) => unsupported("downloads.download", cb) },
    permissions: { request: (_args, cb) => unsupported("permissions.request", cb), remove: (_args, cb) => unsupported("permissions.remove", cb), contains: (_args, cb) => unsupported("permissions.contains", cb) },
    identity: { launchWebAuthFlow: (_args, cb) => unsupported("identity.launchWebAuthFlow", cb) }
  };
  Object.defineProperty(globalThis, "chrome", { value: chrome, configurable: false });
  Object.defineProperty(globalThis, "__CC98IOS__", { value: Object.freeze({ version: 1, receiveStorageChanges, dispatchMessage,
    open: (url, target = "_blank") => call("host.open", { url, target }), share: args => call("host.share", args),
    report, capabilities: Object.freeze({ oauth: false, question: false, semantic: false, subframes: false, chromeDownloads: false }) }) });
  globalThis.addEventListener?.("securitypolicyviolation", event => report("csp.violation", { directive: event.effectiveDirective || "unknown", code: "CSP_BLOCKED" }));
  globalThis.addEventListener?.("error", event => {
    const resource = event.target?.getAttribute?.("src") || event.target?.getAttribute?.("href");
    if (typeof resource === "string" && resource.startsWith(base)) report("resource.error", { resource: resource.slice(base.length).split(/[?#]/)[0], code: "RESOURCE_LOAD_FAILED" });
    else if (typeof event.filename === "string" && event.filename.startsWith(base)) report("runtime.error", { code: "SCRIPT_ERROR", line: event.lineno, column: event.colno });
  }, true);
  if (globalThis.MutationObserver && globalThis.document) {
    const seen = new WeakSet();
    new MutationObserver(records => {
      for (const record of records) for (const node of record.addedNodes || []) {
        const frames = node.matches?.("iframe") ? [node] : [...(node.querySelectorAll?.("iframe") || [])];
        for (const frame of frames) if (!seen.has(frame)) {
          seen.add(frame);
          const drawer = String(frame.name || "").startsWith("cc98-reborn-topic-drawer:");
          const settings = /popup\/(?:popup|semantic-settings)\.html/.test(frame.getAttribute?.("src") || "");
          if (drawer || settings) {
            report("iframe.unsupported", { code: "UNSUPPORTED_SUBFRAME" });
            const notice = document.createElement("p");
            notice.className = "cc98-ios-unsupported";
            notice.setAttribute("role", "status");
            notice.textContent = drawer ? "此验证壳尚未接入帖子侧窗，请关闭侧窗并用新窗口或原站模式阅读。" : "此验证壳尚未接入嵌入式插件设置；可使用 App 的原站／增强切换。";
            const header = drawer && frame.closest?.(".cc98-topic-drawer-panel")?.querySelector?.(".cc98-topic-drawer-header");
            if (header) header.append(notice); else frame.parentNode?.insertBefore(notice, frame);
          }
        }
      }
    }).observe(document, { subtree: true, childList: true });
  }
  report("runtime.ready", { code: "READY" });
})();
