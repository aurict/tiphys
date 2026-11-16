// Status + optional "Page content" permission. permissions.request only works from a user click.
const $ = (id) => document.getElementById(id);
const set = (id, ok, yes, no) => {
  $(id).textContent = ok ? yes : no;
  $(id).className = ok ? "ok" : "no";
};
let request = null;

async function refresh() {
  const s = await browser.runtime.sendMessage({ type: "status" });
  request = s.request;
  set("host", s.host, "çalışıyor", "yok (tiphys-agent firefox install)");
  set("agent", s.agent, "bağlı", "bağlı değil");
  set("content", s.content, "izin verildi", "izin yok");
  $("grant").hidden = s.content;
  $("revoke").hidden = !s.content;
}

$("grant").addEventListener("click", () => {
  if (request) void browser.permissions.request(request).then(refresh, refresh);
});
$("revoke").addEventListener("click", () => {
  if (request) void browser.permissions.remove(request).then(refresh, refresh);
});
void refresh();
