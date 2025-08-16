// bg.js — Chrome Saver (Battery Prompt) v1.0.0
// - Polls a local relay on 127.0.0.1:8165
// - Prompts the user (Yes/No) before applying Chrome-side "battery saver"
// - Sends a versioned heartbeat so the relay can verify compatibility

const RELAY = "http://127.0.0.1:8165";
const VERSION = "1.0.0";         // extension version
const ICON = "icon128.png";      // ensure this file exists in the extension folder

const POLL_SECONDS = 5;          // how often to check relay status
const HEARTBEAT_SECONDS = 60;    // how often to ping relay with version
const COOLDOWN_MS = 3 * 60 * 1000; // min time between "apply saver" actions
const NOTIF_ID = "chrome-saver-notice";

let lastAction = 0;

async function heartbeat() {
  try {
    await fetch(`${RELAY}/ext-heartbeat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ version: VERSION })
    });
  } catch {}
}

async function pollOnce() {
  try {
    const s = await fetch(`${RELAY}/status`, { cache: "no-store" }).then(r => r.json());
    if (s.signal !== "terminate-chrome") return;

    const payload = await fetch(`${RELAY}/payload`, { cache: "no-store" })
      .then(r => r.json())
      .catch(() => ({}));

    const pct = payload.battery_pct ?? "?";
    const dr  = payload.drop_per_min ?? "?";
    const w   = payload.watts ?? "?";

    const now = Date.now();
    if (now - lastAction < COOLDOWN_MS) return;

    chrome.notifications.create(NOTIF_ID, {
      type: "basic",
      iconUrl: ICON,
      title: "Battery draining fast",
      message: `Battery ${pct}% • ${dr}%/min • ${w}W\nReduce Chrome load?`,
      buttons: [
        { title: "Yes — Apply Battery Saver" },
        { title: "No — I'll handle it" }
      ],
      requireInteraction: true,
      priority: 2
    }, () => {});

    // Clear the relay so we don’t immediately re-prompt
    fetch(`${RELAY}/clear`, { method: "POST" }).catch(()=>{});
  } catch {
    // Relay not reachable → ignore quietly
  }
}

function ensurePolling() {
  // Kick off immediately
  pollOnce();
  heartbeat();

  // Alarms for polling/heartbeat so the worker can sleep and wake reliably
  chrome.alarms.clear("poll", () => {
    chrome.alarms.create("poll", { periodInMinutes: POLL_SECONDS / 60 });
  });
  chrome.alarms.clear("hb", () => {
    chrome.alarms.create("hb", { periodInMinutes: HEARTBEAT_SECONDS / 60 });
  });
}

chrome.runtime.onInstalled.addListener(ensurePolling);
chrome.runtime.onStartup?.addListener(ensurePolling);
ensurePolling(); // also run on reloads

chrome.alarms.onAlarm.addListener(a => {
  if (a.name === "poll")      pollOnce();
  else if (a.name === "hb")   heartbeat();
});

// Handle Yes/No notification
chrome.notifications.onButtonClicked.addListener(async (id, btnIndex) => {
  if (id !== NOTIF_ID) return;

  if (btnIndex === 0) {
    // YES — apply Chrome-side "battery saver"
    try {
      const tabs = await chrome.tabs.query({});

      // 1) Mute all tabs
      await Promise.all(tabs.map(t => chrome.tabs.update(t.id, { muted: true }).catch(()=>{})));

      // 2) Discard background tabs (keep the active tab in each window)
      const wins = await chrome.windows.getAll({ populate: true });
      const activeIds = new Set();
      wins.forEach(w => {
        const a = (w.tabs || []).find(t => t.active);
        if (a) activeIds.add(a.id);
      });
      for (const t of tabs) {
        if (!activeIds.has(t.id)) {
          try { await chrome.tabs.discard(t.id); } catch {}
        }
      }

      chrome.notifications.create({
        type: "basic",
        iconUrl: ICON,
        title: "Battery Saver applied",
        message: "Muted tabs and suspended background tabs. Close unused windows for more savings.",
        priority: 1
      }, () => {});
      lastAction = Date.now();
    } catch (e) {
      chrome.notifications.create({
        type: "basic",
        iconUrl: ICON,
        title: "Battery Saver error",
        message: String(e),
        priority: 2
      }, () => {});
    }
  } else {
    // NO — give a friendly tip
    chrome.notifications.create({
      type: "basic",
      iconUrl: ICON,
      title: "Tip to save battery",
      message: "Close unused windows, pause video/audio, or quit Chrome when possible.",
      priority: 0
    }, () => {});
  }

  chrome.notifications.clear(NOTIF_ID);
});

