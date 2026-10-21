// Chrome (Manifest V3) service worker.
//
// - Watches network traffic for video and audio, from ANY frame of a page, the way IDM does, so the
//   "Download this video" bar appears even when the player sits in an embedded frame or its address
//   has no .mp4 / .m3u8 ending.
// - Remembers the browser's own Referer, cookies and User-Agent for each find, so MacDM can download
//   from servers that refuse a request without them.
// - Relays messages from content.js (video bar) to the MacDM app.
// - Captures browser downloads and hands them to MacDM instead.
// - Adds a right-click "Send to MacDM" item for links and media.
//
// Transport: HTTP POST to MacDM's loopback server. MacDM only accepts requests whose Origin is a
// browser-extension origin, which fetch() from this service worker provides automatically.

const MACDM_ENDPOINT = "http://127.0.0.1:57643/api";
const MENU_ID = "macdm-send";

// ---------- talking to MacDM ----------

async function sendToMacDM(payload) {
  try {
    const response = await fetch(MACDM_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    return await response.json();
  } catch (_) {
    return { ok: false, error: "Could not reach MacDM. Make sure the MacDM app is running." };
  }
}

// ---------- recognising media in network traffic ----------

const MIN_FILE_BYTES = 300 * 1024;   // smaller media files are sounds, ads and thumbnails, not downloads
const MAX_ITEMS_PER_TAB = 30;
// Players fetch video from these; they are handled by the page address (yt-dlp), not by the raw chunks.
const IGNORED_HOSTS = /(^|\.)(googlevideo\.com|youtube\.com|ytimg\.com|doubleclick\.net|googleadservices\.com|googlesyndication\.com)$/i;

/** Decides whether a response is a video/audio worth offering. Returns { kind } or null. */
function classifyMedia({ url, contentType = "", size = 0 }) {
  let path;
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    if (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost") return null;   // MacDM itself
    if (IGNORED_HOSTS.test(parsed.hostname)) return null;
    path = parsed.pathname.toLowerCase();
  } catch (_) {
    return null;
  }
  const type = String(contentType).toLowerCase().split(";")[0].trim();

  if (type.includes("mpegurl") || path.endsWith(".m3u8")) return { kind: "hls" };
  if (type === "application/dash+xml" || path.endsWith(".mpd")) return { kind: "dash" };

  // Pieces of a stream are not downloads on their own.
  if (type === "video/mp2t" || type === "video/iso.segment" || /\.(ts|m4s|m4f|cmfv|cmfa|aac)$/.test(path)) return null;

  const isMediaType = type.startsWith("video/") || type.startsWith("audio/");
  const hasMediaExtension = /\.(mp4|m4v|webm|mkv|mov|mp3|m4a|flac|ogg|opus|wav)$/.test(path);
  const isGenericType = type === "" || type === "application/octet-stream" || type === "binary/octet-stream";
  if (!(isMediaType || (isGenericType && hasMediaExtension))) return null;

  // An unknown size is fine for video (streamed responses); sounds must be known to be big.
  if (size > 0) return size >= MIN_FILE_BYTES ? { kind: "file" } : null;
  return type.startsWith("video/") ? { kind: "file" } : null;
}

/** The full file size from Content-Range ("bytes 0-99/12345") or Content-Length. 0 if unknown. */
function responseSize(headers) {
  const range = headers["content-range"];
  const total = range && /\/(\d+)\s*$/.exec(range);
  if (total) return parseInt(total[1], 10);
  const length = headers["content-length"];
  return length ? (parseInt(length, 10) || 0) : 0;
}

function lowerCaseHeaders(list) {
  const result = {};
  for (const header of list || []) {
    if (header && header.name) result[header.name.toLowerCase()] = header.value || "";
  }
  return result;
}

/** The request headers a download needs to look like the browser's own. */
function pickRequestHeaders(list) {
  const wanted = { "referer": "Referer", "cookie": "Cookie", "user-agent": "User-Agent", "origin": "Origin" };
  const result = {};
  for (const header of list || []) {
    const canonical = header && header.name && wanted[header.name.toLowerCase()];
    if (canonical && header.value) result[canonical] = header.value;
  }
  return result;
}

// ---------- remembering finds per tab ----------
// Kept in session storage because the service worker can be stopped and restarted at any moment.

const pendingRequests = new Map();   // requestId -> request headers, until the response arrives

async function loadTab(tabId) {
  const key = `media:${tabId}`;
  const stored = await chrome.storage.session.get(key);
  return Array.isArray(stored[key]) ? stored[key] : [];
}

async function saveTab(tabId, items) {
  await chrome.storage.session.set({ [`media:${tabId}`]: items });
  try {
    await chrome.action.setBadgeText({ tabId, text: items.length ? String(items.length) : "" });
    if (items.length) await chrome.action.setBadgeBackgroundColor({ tabId, color: "#1a73e8" });
  } catch (_) {
    // the tab may be gone
  }
}

async function addMediaItem(tabId, item) {
  const items = await loadTab(tabId);
  if (items.some((existing) => existing.url === item.url)) return;
  items.push(item);
  await saveTab(tabId, items.slice(-MAX_ITEMS_PER_TAB));
  // Tell the page's video bar to refresh. The page may not have the script yet; that's fine.
  try {
    await chrome.tabs.sendMessage(tabId, { type: "media-detected" }, { frameId: 0 });
  } catch (_) {
    // no listener in that tab
  }
}

async function clearTab(tabId) {
  await chrome.storage.session.remove(`media:${tabId}`);
  try { await chrome.action.setBadgeText({ tabId, text: "" }); } catch (_) { /* tab gone */ }
}

// ---------- network listeners ----------

const WATCHED = { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other"] };

function onSendHeaders(details) {
  if (details.tabId < 0) return;
  pendingRequests.set(details.requestId, pickRequestHeaders(details.requestHeaders));
  if (pendingRequests.size > 400) pendingRequests.delete(pendingRequests.keys().next().value);
}

async function onHeadersReceived(details) {
  const requestHeaders = pendingRequests.get(details.requestId) || {};
  pendingRequests.delete(details.requestId);
  if (details.tabId < 0) return;                                   // not from a tab
  if (details.statusCode !== 200 && details.statusCode !== 206) return;

  const headers = lowerCaseHeaders(details.responseHeaders);
  const contentType = headers["content-type"] || "";
  const size = responseSize(headers);
  const found = classifyMedia({ url: details.url, contentType, size });
  if (!found) return;

  await addMediaItem(details.tabId, {
    url: details.url,
    kind: found.kind,
    size,
    contentType,
    headers: requestHeaders,
    time: Date.now()
  });
}

if (chrome.webRequest) {
  chrome.webRequest.onSendHeaders.addListener(onSendHeaders, WATCHED, ["requestHeaders", "extraHeaders"]);
  chrome.webRequest.onHeadersReceived.addListener(onHeadersReceived, WATCHED, ["responseHeaders", "extraHeaders"]);
}

// A new page in a tab starts with a clean list.
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading" && changeInfo.url) clearTab(tabId);
});
chrome.tabs.onRemoved.addListener((tabId) => clearTab(tabId));

// ---------- messages from content.js ----------

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message) return;

  if (message.type === "media-list") {
    const tabId = sender && sender.tab && sender.tab.id;
    if (tabId === undefined) { sendResponse({ items: [] }); return; }
    loadTab(tabId).then((items) => sendResponse({ items }));
    return true; // keep the channel open for the async reply
  }

  if (message.type === "native") {
    sendToMacDM(message.payload).then(sendResponse);
    return true;
  }
});

// ---------- download capture ----------

chrome.downloads.onCreated.addListener(async (item) => {
  const url = item.finalUrl || item.url;
  if (!url || !/^https?:/i.test(url)) return; // skip blob:, data:, file:

  const reply = await sendToMacDM({
    action: "download",
    url,
    sizeBytes: item.fileSize > 0 ? item.fileSize : undefined,
    suggestedFileName: item.filename ? item.filename.split(/[\\/]/).pop() : undefined,
    sourcePageURL: item.referrer || undefined,
    headers: item.referrer ? { Referer: item.referrer } : undefined
  });

  // Only take over when MacDM actually queued it; otherwise let Chrome finish.
  if (reply && reply.ok && !reply.skipped) {
    try {
      await chrome.downloads.cancel(item.id);
      await chrome.downloads.erase({ id: item.id });
    } catch (_) {
      // already finished or gone
    }
  }
});

// ---------- context menu ----------

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: MENU_ID,
    title: "Send to MacDM",
    contexts: ["link", "video", "audio"]
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== MENU_ID) return;
  const url = info.linkUrl || info.srcUrl;
  if (!url) return;
  const page = (tab && tab.url) || undefined;
  sendToMacDM({
    action: "download",
    url,
    forced: true,
    sourcePageURL: page,
    headers: page ? { Referer: page } : undefined
  });
});
