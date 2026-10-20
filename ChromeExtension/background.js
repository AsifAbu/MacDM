// Chrome (Manifest V3) service worker.
//
// - Relays messages from content.js (video bar) to the MacDM app.
// - Captures browser downloads and hands them to MacDM instead.
// - Adds a right-click "Send to MacDM" item for links and media.
//
// Transport: HTTP POST to MacDM's loopback server. MacDM only accepts requests
// whose Origin is a browser-extension origin, which fetch() from this service
// worker provides automatically.

const MACDM_ENDPOINT = "http://127.0.0.1:57643/api";
const MENU_ID = "macdm-send";

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

// ---------- messages from content.js ----------

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "native") return;

  sendToMacDM(message.payload).then(sendResponse);
  return true; // keep the channel open for the async reply
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
    sourcePageURL: item.referrer || undefined
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
  sendToMacDM({
    action: "download",
    url,
    forced: true,
    sourcePageURL: (tab && tab.url) || undefined
  });
});
