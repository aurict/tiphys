// Uptime Kuma'yı ilk kez kurar ve yayındaki siteleri izlemeye alır. Tekrar çalıştırmak güvenlidir:
// var olan kullanıcı, bildirim, monitör ve durum sayfası yeniden oluşturulmaz.
//
// Ortam değişkenleri: UK_URL, UK_USER, UK_PASS, NTFY_TOKEN
// Kullanım: UK_URL=... UK_USER=... UK_PASS=... NTFY_TOKEN=... node seed.mjs
import { readFileSync } from "node:fs";
import { io } from "socket.io-client";

const { UK_URL, UK_USER, UK_PASS, NTFY_TOKEN } = process.env;
for (const [k, v] of Object.entries({ UK_URL, UK_USER, UK_PASS, NTFY_TOKEN })) {
  if (!v) throw new Error(`${k} eksik`);
}

// İzlenecek siteler: UK_SITES (JSON dosyası yolu), yoksa bu klasördeki sites.json (repoda değil;
// biçim için bkz. sites.example.json): [{ "name": "...", "url": "https://..." }]
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

// 1) İlk kurulum (yönetici zaten varsa sunucu reddeder; sorun değil)
const setup = await emit("setup", UK_USER, UK_PASS);
console.log(setup.ok ? "Yönetici oluşturuldu." : "Yönetici zaten var.");

// 2) Giriş. Giriş sonrası sunucu monitör ve bildirim listelerini kendisi gönderir.
const monitorListP = nextEvent("monitorList");
const notificationListP = nextEvent("notificationList");
must(await emit("login", { username: UK_USER, password: UK_PASS, token: "" }), "giriş");
const monitors = Object.values(await monitorListP);
const notifications = await notificationListP;

// 3) ntfy bildirimi (varsayılan; yeni monitörlere de otomatik eklenir)
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

// 4) Monitörler: 60 sn aralık, 1 tekrar → yaklaşık 2 dk kesintide bildirim
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

// 5) Durum sayfası (Homepage kartı ve telefon için özet)
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
