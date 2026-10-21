// Shared helpers for the extension tests.
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..", "..");
const file = (...parts) => path.join(root, ...parts);
const read = (...parts) => fs.readFileSync(file(...parts), "utf8");

/**
 * Runs background.js against a mocked `chrome` API and a scripted `fetch`.
 * `reply` is what MacDM "answers": an object, or an Error to simulate the app not running.
 */
function loadBackground({ reply = { ok: true }, script = "ChromeExtension/background.js" } = {}) {
  const listeners = {};
  const calls = { fetch: [], cancel: [], erase: [], menus: [], badges: [], tabMessages: [] };
  const session = {};   // stands in for chrome.storage.session

  const chrome = {
    runtime: {
      onMessage: { addListener: (fn) => (listeners.message = fn) },
      onInstalled: { addListener: (fn) => (listeners.installed = fn) }
    },
    webRequest: {
      onSendHeaders: { addListener: (fn, filter, extra) => { listeners.sendHeaders = fn; listeners.sendHeadersExtra = extra; } },
      onHeadersReceived: { addListener: (fn, filter, extra) => { listeners.headersReceived = fn; listeners.headersReceivedExtra = extra; } }
    },
    tabs: {
      onUpdated: { addListener: (fn) => (listeners.tabUpdated = fn) },
      onRemoved: { addListener: (fn) => (listeners.tabRemoved = fn) },
      sendMessage: async (tabId, message, options) => { calls.tabMessages.push(JSON.parse(JSON.stringify({ tabId, message, options }))); }
    },
    storage: {
      session: {
        get: async (key) => (key in session ? { [key]: JSON.parse(JSON.stringify(session[key])) } : {}),
        set: async (values) => { for (const [k, v] of Object.entries(values)) session[k] = JSON.parse(JSON.stringify(v)); },
        remove: async (key) => { delete session[key]; }
      }
    },
    action: {
      setBadgeText: async (details) => calls.badges.push(JSON.parse(JSON.stringify(details))),
      setBadgeBackgroundColor: async () => {}
    },
    downloads: {
      onCreated: { addListener: (fn) => (listeners.download = fn) },
      cancel: async (id) => calls.cancel.push(id),
      erase: async (query) => calls.erase.push(JSON.parse(JSON.stringify(query)))
    },
    contextMenus: {
      create: (item) => calls.menus.push(item),
      onClicked: { addListener: (fn) => (listeners.menuClick = fn) }
    }
  };
  // Safari's background script uses `browser`; give it the same mock.
  const browser = {
    runtime: {
      onMessage: chrome.runtime.onMessage,
      sendNativeMessage: async () => { throw new Error("no native host"); }
    }
  };

  const fetch = async (url, options) => {
    calls.fetch.push({ url, body: JSON.parse(options.body), options });
    if (reply instanceof Error) throw reply;
    return { json: async () => reply };
  };

  const context = vm.createContext({ chrome, browser, fetch, console, JSON, Promise, setTimeout, URL, Map, Date });
  vm.runInContext(read(script), context, { filename: script });
  return { listeners, calls, session, context };
}

module.exports = { root, file, read, loadBackground };
