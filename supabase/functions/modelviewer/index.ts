// Proxy for the files of Wowhead's 3D model viewer, used by the character card in index.html.
// wow.zamimg.com answers 403 to requests that come from other sites (CORS), so the browser cannot load them directly.
// Only GET, only files under modelviewer/classicplus/ (the WoW Forever models). Deploy with JWT verification OFF:
// the viewer requests its files itself and sends no token.
const UP = "https://wow.zamimg.com/modelviewer/classicplus/";
const CORS = { "Access-Control-Allow-Origin": "*" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { ...CORS, "Access-Control-Allow-Methods": "GET", "Access-Control-Allow-Headers": "*" } });
  }
  if (req.method !== "GET") return new Response("GET only", { status: 405, headers: CORS });
  const path = new URL(req.url).pathname.split("/modelviewer/")[1] ?? "";
  if (!/^[\w.-]+(\/[\w.-]+)*$/.test(path) || path.split("/").includes("..")) {
    return new Response("bad path", { status: 400, headers: CORS });
  }
  const r = await fetch(UP + path);
  const h = new Headers(CORS);
  h.set("Content-Type", r.headers.get("Content-Type") ?? "application/octet-stream");
  if (r.ok) h.set("Cache-Control", "public, max-age=604800"); // the files are versioned, a week in the browser cache is safe
  return new Response(r.body, { status: r.status, headers: h });
});
