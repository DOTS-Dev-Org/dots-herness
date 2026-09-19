const STORAGE_KEY = "herness.browser.leases.v1";
const ALARM_NAME = "herness.browser.orphan-sweep";
const NATIVE_HOST = "com.dots.herness.browser";
const LEASE_MS = 90_000;

let nativePort = null;

function isWebURL(value) {
  try {
    const url = new URL(String(value));
    return url.protocol === "http:" || url.protocol === "https:";
  } catch (_) {
    return false;
  }
}

function scopeKey(scope) {
  if (!scope || typeof scope !== "object") return null;
  const area = String(scope.area || "").trim();
  const conversationID = String(scope.conversationID || "").trim();
  const runID = String(scope.runID || "").trim();
  if (!area || !conversationID || !runID) return null;
  return `${area}:${conversationID}:${runID}`;
}

async function readLeases() {
  const stored = await chrome.storage.local.get(STORAGE_KEY);
  return stored[STORAGE_KEY] && typeof stored[STORAGE_KEY] === "object"
    ? stored[STORAGE_KEY]
    : {};
}

async function writeLeases(leases) {
  await chrome.storage.local.set({ [STORAGE_KEY]: leases });
}

function response(requestID, payload) {
  return { requestID: String(requestID || ""), ...payload };
}

async function closeLease(lease, leases) {
  if (!lease || !Number.isInteger(lease.tabID)) return;
  try {
    await chrome.tabs.remove(lease.tabID);
  } catch (_) {
    // tabs.onRemoved or a closed window already completed cleanup.
  }
  delete leases[lease.leaseID];
}

async function closeScope(scope, leases, connectionID = null) {
  const key = scopeKey(scope);
  if (!key) throw new Error("scope is required");
  for (const lease of Object.values(leases)) {
    if (lease.scopeKey === key && (connectionID === null || lease.connectionID === connectionID)) {
      await closeLease(lease, leases);
    }
  }
}

async function sweepExpired() {
  const leases = await readLeases();
  const now = Date.now();
  for (const lease of Object.values(leases)) {
    if (!lease || lease.leaseExpiresAt > now) continue;
    await closeLease(lease, leases);
  }
  await writeLeases(leases);
}

async function openTab(message, connectionID) {
  if (!isWebURL(message.url)) throw new Error("Only http and https URLs are allowed");
  const key = scopeKey(message.scope);
  if (!key) throw new Error("scope is required");
  const tab = await chrome.tabs.create({ url: message.url, active: false });
  const leaseID = crypto.randomUUID();
  const leases = await readLeases();
  leases[leaseID] = {
    leaseID,
    runID: String(message.scope.runID),
    scope: message.scope,
    scopeKey: key,
    tabID: tab.id,
    windowID: tab.windowId,
    connectionID,
    url: String(message.url),
    leaseExpiresAt: Date.now() + LEASE_MS,
  };
  try {
    await writeLeases(leases);
  } catch (error) {
    try { await chrome.tabs.remove(tab.id); } catch (_) { }
    throw error;
  }
  return { leaseID, pageID: String(tab.id), tabID: tab.id, windowID: tab.windowId };
}

async function touchLease(message, leases, connectionID) {
  const leaseID = String(message.leaseID || "");
  const lease = leases[leaseID];
  if (!lease || lease.scopeKey !== scopeKey(message.scope) || lease.connectionID !== connectionID) {
    throw new Error("page is not owned by this run");
  }
  lease.leaseExpiresAt = Date.now() + LEASE_MS;
  return lease;
}

async function handleNativeMessage(message, connectionID) {
  if (!message || typeof message !== "object") throw new Error("invalid Native Messaging message");
  if (message.backend !== undefined) throw new Error("backend is selected by the host, not by the extension request");

  const leases = await readLeases();
  switch (message.type) {
    case "ping":
      return { state: "ready" };
    case "open": {
      const page = await openTab(message, connectionID);
      return { pageID: page.pageID, leaseID: page.leaseID, windowID: page.windowID };
    }
    case "navigate": {
      if (!isWebURL(message.url)) throw new Error("Only http and https URLs are allowed");
      const lease = await touchLease(message, leases, connectionID);
      await chrome.tabs.update(lease.tabID, { url: message.url });
      lease.url = String(message.url);
      await writeLeases(leases);
      return { pageID: String(lease.tabID) };
    }
    case "close": {
      const lease = await touchLease(message, leases, connectionID);
      await closeLease(lease, leases);
      await writeLeases(leases);
      return { pageID: String(lease.tabID) };
    }
    case "cleanup":
      await closeScope(message.scope, leases, connectionID);
      await writeLeases(leases);
      return { cleanupStatus: "Closed" };
    default:
      throw new Error(`unknown request type: ${String(message.type || "")}`);
  }
}

async function recoverAfterChromeStartup() {
  const leases = await readLeases();
  for (const [leaseID, lease] of Object.entries(leases)) {
    let tab;
    try {
      tab = await chrome.tabs.get(lease.tabID);
    } catch (_) {
      delete leases[leaseID];
      continue;
    }
    const sameWindow = tab.windowId === lease.windowID;
    const knownURL = String(lease.url || "");
    const sameURL = !knownURL || tab.url === knownURL || tab.pendingUrl === knownURL;
    if (sameWindow && sameURL) await closeLease(lease, leases);
    else delete leases[leaseID];
  }
  await writeLeases(leases);
  await sweepExpired();
}

function connectNative() {
  if (nativePort) return;
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  } catch (_) {
    nativePort = null;
    return;
  }
  const connectionID = crypto.randomUUID();
  nativePort.onMessage.addListener(async message => {
    const requestID = message && message.requestID;
    try {
      nativePort?.postMessage(response(requestID, { ok: true, result: await handleNativeMessage(message, connectionID) }));
    } catch (error) {
      nativePort?.postMessage(response(requestID, { ok: false, error: String(error?.message || error) }));
    }
  });
  nativePort.onDisconnect.addListener(async () => {
    nativePort = null;
    // The native host owns the connection. The connection ID is persisted in
    // every lease, so a service-worker restart cannot make disconnect cleanup
    // lose ownership information kept only in worker memory.
    const leases = await readLeases();
    for (const lease of Object.values(leases)) {
      if (lease.connectionID === connectionID) await closeLease(lease, leases);
    }
    await writeLeases(leases);
  });
}

chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create(ALARM_NAME, { periodInMinutes: 0.5 });
  void recoverAfterChromeStartup();
  connectNative();
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(ALARM_NAME, { periodInMinutes: 0.5 });
  void recoverAfterChromeStartup();
  connectNative();
});

chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name !== ALARM_NAME) return;
  if (!nativePort) connectNative();
  void sweepExpired();
});

chrome.tabs.onRemoved.addListener(async tabID => {
  const leases = await readLeases();
  let changed = false;
  for (const [leaseID, lease] of Object.entries(leases)) {
    if (lease.tabID !== tabID) continue;
    delete leases[leaseID];
    changed = true;
  }
  if (changed) await writeLeases(leases);
});

chrome.tabs.onUpdated.addListener(async (tabID, changeInfo) => {
  if (!changeInfo.url) return;
  const leases = await readLeases();
  let changed = false;
  for (const lease of Object.values(leases)) {
    if (lease.tabID !== tabID) continue;
    lease.url = changeInfo.url;
    lease.leaseExpiresAt = Date.now() + LEASE_MS;
    changed = true;
  }
  if (changed) await writeLeases(leases);
});

void chrome.alarms.create(ALARM_NAME, { periodInMinutes: 0.5 });
connectNative();
