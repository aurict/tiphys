// Tiphys Köprüsü background: native messaging connection, tab events, popup state.
import { Bridge, CONTENT_PERMISSIONS, contentPermission } from "./lib/protocol.js";
import { makeFavicon } from "./lib/favicon.js";

const bridge = new Bridge(browser, { favicon: makeFavicon() });
bridge.start();

// The popup/options page only asks for the state; the permission request is made there (by a user click).
browser.runtime.onMessage.addListener(async (m, sender) => {
  if (sender.id !== browser.runtime.id || m?.type !== "status") return undefined;
  return { ...bridge.status, content: await contentPermission(browser), request: CONTENT_PERMISSIONS };
});
