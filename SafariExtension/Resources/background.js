// Safari Web Extension background script.
//
// Safari has no `downloads` API, so capture happens in content.js (video bar and
// media sniffing). This script relays messages from the page to the MacDM app.
//
// Primary transport: HTTP POST to MacDM's loopback server. This works for a
// plain (temporary / unsigned) web extension. If that fails, fall back to
// native messaging, which Safari routes to SafariWebExtensionHandler.swift.

const MACDM_ENDPOINT = "http://127.0.0.1:57643/api";

async function sendToMacDM(payload) {
  try {
    const response = await fetch(MACDM_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    return await response.json();
  } catch (httpError) {
    try {
      const reply = await browser.runtime.sendNativeMessage("application.id", payload);
      if (reply) return reply;
    } catch (_) {
      // fall through to the friendly error below
    }
    return { ok: false, error: "Could not reach MacDM. Make sure the MacDM app is running." };
  }
}

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "native") return;

  sendToMacDM(message.payload).then(sendResponse);
  return true; // keep the channel open for the async reply
});
