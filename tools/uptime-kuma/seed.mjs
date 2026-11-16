// Sets up Uptime Kuma for the first time and starts monitoring the live sites. Safe to re-run:
// an existing user, notification, monitor and status page are not recreated.
//
// Environment variables: UK_URL, UK_USER, UK_PASS, NTFY_TOKEN
// Usage: UK_URL=... UK_USER=... UK_PASS=... NTFY_TOKEN=... node seed.mjs
import { readFileSync } from "node:fs";
import { io } from "socket.io-client";

const { UK_URL, UK_USER, UK_PASS, NTFY_TOKEN } = process.env;
for (const [k, v] of Object.entries({ UK_URL, UK_USER, UK_PASS, NTFY_TOKEN })) {
  if (!v) throw new Error(`${k} eksik`);
}

// Sites to monitor: UK_SITES (path to a JSON file), otherwise sites.json in this folder (not in the repo;
// see sites.example.json for the format): [{ "name": "...", "url": "https://..." }]
const SITES = JSON.parse(
  readFileSync(process.env.UK_SITES ?? new URL("./sites.json", import.meta.url), "utf8"),
);const NOTIFICATION_NAME = "ntfy · siteler";
const STATUS_SLUG = "siteler";

const socket = io(UK_URL, { transports: ["websocket"], reconnection: false, timeout: 15000 });

function emit(event, ...args) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`zaman aşımı: ${event}`)), 20000);
    socket.emit(event, ...args, (res) => {
      clearTimeout(timer);
      resolve(res);
    });
  });
}

function nextEvent(name) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`zaman aşımı: ${name} olayı`)), 20000);
    socket.once(name, (data) => {
      clearTimeout(timer);
      resolve(data);
    });
  });
}

function must(res, what) {
  if (!res?.ok) throw new Error(`${what}: ${res?.msg ?? "bilinmeyen hata"}`);
  return res;
}

await new Promise((resolve, reject) => {
  socket.once("connect", resolve);
  socket.once("connect_error", reject);
});

// 1) Initial setup (the server refuses if an admin already exists; that's fine)
const setup = await emit("setup", UK_USER, UK_PASS);
console.log(setup.ok ? "Yönetici oluşturuldu." : "Yönetici zaten var.");

// 2) Login. After login the server sends the monitor and notification lists by itself.
const monitorListP = nextEvent("monitorList");
const notificationListP = nextEvent("notificationList");
must(await emit("login", { username: UK_USER, password: UK_PASS, token: "" }), "giriş");
const monitors = Object.values(await monitorListP);
const notifications = await notificationListP;

// 3) ntfy notification (default; also added automatically to new monitors)
let notification = notifications.find((n) => n.name === NOTIFICATION_NAME);
let notificationId = notification?.id;
if (!notificationId) {
  const res = must(
    await emit(
      "addNotification",
      {
        name: NOTIFICATION_NAME,
        type: "ntfy",
        isDefault: true,
        applyExisting: true,
        active: true,
        ntfyserverurl: "http://ntfy",
        ntfytopic: "siteler",
        ntfyPriority: 4,
        ntfyPriorityDown: 5,
        ntfyAuthenticationMethod: "accessToken",
        ntfyaccesstoken: NTFY_TOKEN,
      },
      null,
    ),
    "bildirim ekleme",
  );
  notificationId = res.id;
  console.log(`Bildirim eklendi (#${notificationId}).`);
} else {
  console.log(`Bildirim zaten var (#${notificationId}).`);
}

// 4) Monitors: 60 s interval, 1 retry → notification after roughly 2 min of downtime
const ids = [];
for (const site of SITES) {
  const existing = monitors.find((m) => m.url === site.url);
  if (existing) {
    ids.push(existing.id);
    console.log(`Var: ${site.name} (#${existing.id})`);
    continue;
  }
  const res = must(
    await emit("add", {
      type: "http",
      name: site.name,
      url: site.url,
      method: "GET",
      interval: 60,
      retryInterval: 60,
      resendInterval: 0,
      maxretries: 1,
      timeout: 30,
      accepted_statuscodes: ["200-299"],
      maxredirects: 10,
      expiryNotification: true,
      ignoreTls: false,
      upsideDown: false,
      notificationIDList: { [notificationId]: true },
      kafkaProducerBrokers: [],
      kafkaProducerSaslOptions: { mechanism: "None" },
      rabbitmqNodes: [],
      conditions: [],
      active: true,
    }),
    `monitör ekleme: ${site.name}`,
  );
  ids.push(res.monitorID);
  console.log(`Eklendi: ${site.name} (#${res.monitorID})`);
}

// 5) Status page (summary for the Homepage card and the phone)
const sp = await emit("getStatusPage", STATUS_SLUG);
if (!sp?.ok) {
  must(await emit("addStatusPage", "Siteler", STATUS_SLUG), "durum sayfası ekleme");
  console.log("Durum sayfası oluşturuldu.");
}
must(
  await emit(
    "saveStatusPage",
    STATUS_SLUG,
    {
      slug: STATUS_SLUG,
      title: "Siteler",
      description: "Yayındaki siteler",
      logo: "/icon.svg",
      theme: "auto",
      autoRefreshInterval: 60,
      showTags: false,
      footerText: "",
      customCSS: "",
      showPoweredBy: false,
      rssTitle: "",
      showOnlyLastHeartbeat: false,
      showCertificateExpiry: true,
      analyticsId: null,
      analyticsScriptUrl: null,
      analyticsType: null,
      domainNameList: [],
    },
    "/icon.svg",
    [{ name: "Yayındaki siteler", monitorList: ids.map((id) => ({ id })) }],
  ),
  "durum sayfası kaydetme",
);
console.log(`Durum sayfası güncellendi: /status/${STATUS_SLUG} (${ids.length} site).`);

socket.disconnect();
