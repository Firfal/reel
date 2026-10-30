var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/crypto.ts
var encoder = new TextEncoder();
var PBKDF2_ITERATIONS = 1e5;
function toHex(buffer) {
  return Array.from(buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
__name(toHex, "toHex");
function fromHex(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}
__name(fromHex, "fromHex");
async function safeEqual(provided, expected) {
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected))
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}
__name(safeEqual, "safeEqual");
function newSlug(length = 10) {
  const alphabet = "abcdefghijkmnopqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}
__name(newSlug, "newSlug");
async function pbkdf2(password, salt, iterations) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  return crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
}
__name(pbkdf2, "pbkdf2");
async function hashPassword(password) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(password, salt, PBKDF2_ITERATIONS);
  return `pbkdf2$${PBKDF2_ITERATIONS}$${toHex(salt)}$${toHex(hash)}`;
}
__name(hashPassword, "hashPassword");
async function verifyPassword(password, stored) {
  const [scheme, iterations, salt, expected] = stored.split("$");
  if (scheme !== "pbkdf2" || !iterations || !salt || !expected) return false;
  const hash = await pbkdf2(password, fromHex(salt), Number(iterations));
  return safeEqual(toHex(hash), expected);
}
__name(verifyPassword, "verifyPassword");
async function hmac(key, message) {
  const cryptoKey = await crypto.subtle.importKey("raw", encoder.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toHex(await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(message)));
}
__name(hmac, "hmac");
function accessToken(signingKey, videoId, passwordHash) {
  return hmac(signingKey, `access:${videoId}:${passwordHash}`);
}
__name(accessToken, "accessToken");

// src/quota.ts
var QuotaError = class extends Error {
  constructor(reason) {
    super(
      reason === "storage" ? "Storage limit reached: delete or archive videos to free space." : "Monthly sharing limit reached: links work again on the 1st of next month."
    );
    this.reason = reason;
  }
  reason;
  static {
    __name(this, "QuotaError");
  }
};
function currentMonth(now = /* @__PURE__ */ new Date()) {
  return now.toISOString().slice(0, 7);
}
__name(currentMonth, "currentMonth");
async function storageUsed(env) {
  const row = await env.DB.prepare("SELECT COALESCE(SUM(size_bytes), 0) AS used FROM videos").first();
  return row?.used ?? 0;
}
__name(storageUsed, "storageUsed");
async function assertStorageFor(env, extraBytes) {
  const used = await storageUsed(env);
  if (used + extraBytes > Number(env.STORAGE_CAP_BYTES)) throw new QuotaError("storage");
}
__name(assertStorageFor, "assertStorageFor");
async function spendOps(env, kind, count = 1) {
  const column = kind === "write" ? "write_ops" : "read_ops";
  const cap = Number(kind === "write" ? env.WRITE_OPS_CAP_MONTH : env.READ_OPS_CAP_MONTH);
  const month = currentMonth();
  await env.DB.prepare("INSERT OR IGNORE INTO usage (month) VALUES (?)").bind(month).run();
  const result = await env.DB.prepare(`UPDATE usage SET ${column} = ${column} + ? WHERE month = ? AND ${column} + ? <= ?`).bind(count, month, count, cap).run();
  if (result.meta.changes === 0) throw new QuotaError(kind === "write" ? "writes" : "reads");
}
__name(spendOps, "spendOps");
async function usageSummary(env) {
  const month = currentMonth();
  const ops = await env.DB.prepare("SELECT write_ops, read_ops FROM usage WHERE month = ?").bind(month).first();
  return {
    month,
    storageBytes: await storageUsed(env),
    storageCapBytes: Number(env.STORAGE_CAP_BYTES),
    writeOps: ops?.write_ops ?? 0,
    writeOpsCap: Number(env.WRITE_OPS_CAP_MONTH),
    readOps: ops?.read_ops ?? 0,
    readOpsCap: Number(env.READ_OPS_CAP_MONTH)
  };
}
__name(usageSummary, "usageSummary");

// src/store.ts
var DEFAULTS = {
  companyName: "",
  playerColor: "#E2703A",
  hasLogo: false,
  logoVersion: 0,
  defaultPrivacy: "unlisted"
};
async function getSettings(env) {
  const row = await env.DB.prepare("SELECT value FROM settings WHERE key = 'workspace'").first();
  return { ...DEFAULTS, ...row ? JSON.parse(row.value) : {} };
}
__name(getSettings, "getSettings");
async function putSettings(env, changes) {
  const next = { ...await getSettings(env), ...changes };
  if (!/^#[0-9a-fA-F]{6}$/.test(next.playerColor)) next.playerColor = DEFAULTS.playerColor;
  next.companyName = String(next.companyName).slice(0, 80);
  await env.DB.prepare("INSERT INTO settings (key, value) VALUES ('workspace', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").bind(JSON.stringify(next)).run();
  return next;
}
__name(putSettings, "putSettings");

// src/api.ts
var PART_SIZE = 50 * 1024 * 1024;
var MAX_PART_BYTES = 95 * 1024 * 1024;
var MAX_IMAGE_BYTES = 8 * 1024 * 1024;
var PRIVACIES = /* @__PURE__ */ new Set(["public", "unlisted", "password"]);
var HttpError = class extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
  status;
  static {
    __name(this, "HttpError");
  }
};
function videoKey(id) {
  return `videos/${id}/video.mp4`;
}
__name(videoKey, "videoKey");
async function isOwner(request, env) {
  const header = request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  return token.length > 0 && safeEqual(token, env.OWNER_TOKEN);
}
__name(isOwner, "isOwner");
async function readJSON(request) {
  try {
    return await request.json();
  } catch {
    throw new HttpError(400, "Body must be JSON.");
  }
}
__name(readJSON, "readJSON");
async function loadVideo(env, id) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) throw new HttpError(404, "Video not found.");
  return row;
}
__name(loadVideo, "loadVideo");
function contentLength(request, max) {
  const length = Number(request.headers.get("Content-Length"));
  if (!Number.isFinite(length) || length <= 0) throw new HttpError(411, "Content-Length is required.");
  if (length > max) throw new HttpError(413, `Body too large (max ${max} bytes).`);
  return length;
}
__name(contentLength, "contentLength");
async function metadataUpdates(body) {
  const columns = [];
  const values = [];
  const set = /* @__PURE__ */ __name((column, value) => {
    columns.push(`${column} = ?`);
    values.push(value);
  }, "set");
  if (body.title !== void 0) set("title", String(body.title).slice(0, 200));
  if (body.description !== void 0) set("description", String(body.description).slice(0, 5e3));
  if (body.duration !== void 0) set("duration", Number(body.duration) || 0);
  if (body.privacy !== void 0) {
    if (!PRIVACIES.has(body.privacy)) throw new HttpError(400, "privacy must be public, unlisted or password.");
    set("privacy", body.privacy);
  }
  if (body.password !== void 0) set("password_hash", body.password ? await hashPassword(body.password) : null);
  if (body.chapters !== void 0) set("chapters", JSON.stringify(body.chapters ?? []));
  if (body.cta !== void 0) set("cta", body.cta ? JSON.stringify(body.cta) : null);
  if (body.links !== void 0) set("links", JSON.stringify(body.links ?? []));
  if (body.captions !== void 0) set("captions", body.captions);
  return [columns, values];
}
__name(metadataUpdates, "metadataUpdates");
async function handleOwner(request, env, path) {
  const method = request.method;
  if (path[0] === "usage" && method === "GET") return Response.json(await usageSummary(env));
  if (path[0] === "settings") {
    if (method === "GET") return Response.json(await getSettings(env));
    if (method === "PUT") return Response.json(await putSettings(env, await readJSON(request)));
  }
  if (path[0] === "fonts" && path[1] === "InstrumentSans.ttf" && method === "PUT") {
    contentLength(request, MAX_IMAGE_BYTES);
    await spendOps(env, "write");
    await env.VIDEOS.put("public/fonts/InstrumentSans.ttf", request.body, { httpMetadata: { contentType: "font/ttf" } });
    return Response.json({ ok: true });
  }
  if (path[0] === "brand" && path[1] === "logo" && method === "PUT") {
    const length = contentLength(request, MAX_IMAGE_BYTES);
    await spendOps(env, "write");
    await env.VIDEOS.put("brand/logo", request.body, {
      httpMetadata: { contentType: request.headers.get("Content-Type") ?? "image/png" }
    });
    await putSettings(env, { hasLogo: true, logoVersion: Date.now() });
    return Response.json({ ok: true, bytes: length });
  }
  if (path[0] !== "videos") throw new HttpError(404, "Not found.");
  const id = path[1];
  if (!id && method === "GET") {
    const { results } = await env.DB.prepare(
      `SELECT v.id, v.title, v.duration, v.size_bytes, v.status, v.privacy, v.created_at,
              (SELECT COUNT(*) FROM views w WHERE w.video_id = v.id) AS views,
              (SELECT COUNT(*) FROM comments c WHERE c.video_id = v.id) AS comments
       FROM videos v ORDER BY v.created_at DESC`
    ).all();
    return Response.json({ videos: results });
  }
  if (!id && method === "POST") {
    const body = await readJSON(request);
    const sizeBytes = Number(body.sizeBytes);
    if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) throw new HttpError(400, "sizeBytes is required.");
    await assertStorageFor(env, sizeBytes);
    await spendOps(env, "write");
    const slug = newSlug();
    const upload = await env.VIDEOS.createMultipartUpload(videoKey(slug), { httpMetadata: { contentType: "video/mp4" } });
    await env.DB.prepare("INSERT INTO videos (id, title, size_bytes, upload_id) VALUES (?, ?, ?, ?)").bind(slug, body.title?.slice(0, 200) || "Vid\xE9o", sizeBytes, upload.uploadId).run();
    const [columns, values] = await metadataUpdates({ ...body, title: void 0 });
    if (columns.length) {
      await env.DB.prepare(`UPDATE videos SET ${columns.join(", ")} WHERE id = ?`).bind(...values, slug).run();
    }
    const origin = new URL(request.url).origin;
    return Response.json({ id: slug, partSize: PART_SIZE, url: `${origin}/v/${slug}` }, { status: 201 });
  }
  if (!id) throw new HttpError(405, "Method not allowed.");
  const video = await loadVideo(env, id);
  if (path[2] === "replace" && method === "POST") {
    const body = await readJSON(request);
    const sizeBytes = Number(body.sizeBytes);
    if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) throw new HttpError(400, "sizeBytes is required.");
    await assertStorageFor(env, Math.max(0, sizeBytes - video.size_bytes));
    await spendOps(env, "write");
    if (video.upload_id) await env.VIDEOS.resumeMultipartUpload(videoKey(id), video.upload_id).abort().catch(() => {
    });
    const upload = await env.VIDEOS.createMultipartUpload(videoKey(id), { httpMetadata: { contentType: "video/mp4" } });
    const [columns, values] = await metadataUpdates(body);
    await env.DB.prepare(`UPDATE videos SET ${["upload_id = ?", ...columns].join(", ")} WHERE id = ?`).bind(upload.uploadId, ...values, id).run();
    const origin = new URL(request.url).origin;
    return Response.json({ id, partSize: PART_SIZE, url: `${origin}/v/${id}` });
  }
  if (path[2] === "parts" && method === "PUT") {
    const partNumber = Number(path[3]);
    if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 1e4) throw new HttpError(400, "Invalid part number.");
    if (!video.upload_id) throw new HttpError(409, "No upload in progress.");
    contentLength(request, MAX_PART_BYTES);
    await spendOps(env, "write");
    const upload = env.VIDEOS.resumeMultipartUpload(videoKey(id), video.upload_id);
    const part = await upload.uploadPart(partNumber, request.body);
    return Response.json(part);
  }
  if (path[2] === "complete" && method === "POST") {
    if (!video.upload_id) throw new HttpError(409, "No upload in progress.");
    const { parts } = await readJSON(request);
    await spendOps(env, "write");
    const upload = env.VIDEOS.resumeMultipartUpload(videoKey(id), video.upload_id);
    const object = await upload.complete(parts);
    await env.DB.prepare("UPDATE videos SET status = 'ready', upload_id = NULL, size_bytes = ? WHERE id = ?").bind(object.size, id).run();
    return Response.json({ ok: true, size: object.size });
  }
  if ((path[2] === "thumbnail" || path[2] === "preview") && method === "PUT") {
    const length = contentLength(request, MAX_IMAGE_BYTES);
    await assertStorageFor(env, length);
    await spendOps(env, "write");
    const isThumbnail = path[2] === "thumbnail";
    await env.VIDEOS.put(`videos/${id}/${isThumbnail ? "thumbnail.jpg" : "preview.gif"}`, request.body, {
      httpMetadata: { contentType: isThumbnail ? "image/jpeg" : "image/gif" }
    });
    await env.DB.prepare(`UPDATE videos SET ${isThumbnail ? "has_thumbnail" : "has_preview"} = 1, size_bytes = size_bytes + ? WHERE id = ?`).bind(length, id).run();
    return Response.json({ ok: true });
  }
  if (path[2] === "insights" && method === "GET") {
    const [views, comments, reactions] = await Promise.all([
      env.DB.prepare("SELECT viewer, percent, created_at FROM views WHERE video_id = ? ORDER BY created_at DESC LIMIT 500").bind(id).all(),
      env.DB.prepare("SELECT id, author, body, time, created_at FROM comments WHERE video_id = ? ORDER BY created_at").bind(id).all(),
      env.DB.prepare("SELECT kind, COUNT(*) AS count FROM reactions WHERE video_id = ? GROUP BY kind").bind(id).all()
    ]);
    return Response.json({ views: views.results, comments: comments.results, reactions: reactions.results });
  }
  if (!path[2] && method === "PATCH") {
    const [columns, values] = await metadataUpdates(await readJSON(request));
    if (columns.length) await env.DB.prepare(`UPDATE videos SET ${columns.join(", ")} WHERE id = ?`).bind(...values, id).run();
    return Response.json({ ok: true });
  }
  if (!path[2] && method === "DELETE") {
    if (video.upload_id) await env.VIDEOS.resumeMultipartUpload(videoKey(id), video.upload_id).abort().catch(() => {
    });
    await env.VIDEOS.delete([videoKey(id), `videos/${id}/thumbnail.jpg`, `videos/${id}/preview.gif`]);
    await env.DB.batch([
      env.DB.prepare("DELETE FROM comments WHERE video_id = ?").bind(id),
      env.DB.prepare("DELETE FROM reactions WHERE video_id = ?").bind(id),
      env.DB.prepare("DELETE FROM views WHERE video_id = ?").bind(id),
      env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(id)
    ]);
    return Response.json({ ok: true });
  }
  throw new HttpError(405, "Method not allowed.");
}
__name(handleOwner, "handleOwner");

// src/page.ts
var escapeHTML = /* @__PURE__ */ __name((value) => value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]), "escapeHTML");
var inlineJSON = /* @__PURE__ */ __name((value) => JSON.stringify(value).replace(/</g, "\\u003c"), "inlineJSON");
function brand(settings) {
  if (settings.hasLogo) {
    return `<img class="logo" src="/brand/logo?v=${settings.logoVersion}" alt="${escapeHTML(settings.companyName || "Logo")}">`;
  }
  return settings.companyName ? `<span class="wordmark">${escapeHTML(settings.companyName)}</span>` : "";
}
__name(brand, "brand");
var BASE_CSS = `
@font-face{font-family:"Instrument Sans";src:url("/fonts/InstrumentSans.ttf") format("truetype");font-weight:400 700;font-display:swap}
:root{--accent:#E2703A;--canvas:#faf7f4;--surface:#fff;--inset:#f3eee9;--fg:#231c17;--muted:#7a6d64;--line:rgba(70,45,25,.10);--on-accent:#fff;
--display:"Instrument Sans",-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--canvas:#1c1815;--surface:#231e1a;--inset:#191512;--fg:#f3ede8;--muted:#a89a90;--line:rgba(255,235,220,.09);color-scheme:dark}}
*{box-sizing:border-box}
body{margin:0;background:var(--canvas);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--accent)}
button,input,textarea{font:inherit;color:inherit}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.logo{height:28px;width:auto;display:block}
.wordmark{font-family:var(--display);font-weight:700;letter-spacing:-.01em}
`;
var PLAYER_CSS = `
.stage{position:relative;border-radius:14px;overflow:hidden;background:#000}
.stage video{width:100%;display:block;aspect-ratio:16/9;background:#000;cursor:pointer}
.overlay{position:absolute;inset:auto 0 64px 0;display:flex;justify-content:center;gap:8px;pointer-events:none}
.overlay a{pointer-events:auto;background:var(--accent);color:var(--on-accent);text-decoration:none;border-radius:999px;padding:6px 12px;font-size:13px;font-weight:600;box-shadow:0 4px 16px rgba(0,0,0,.25)}
.controls{position:absolute;inset:auto 0 0 0;display:flex;align-items:center;gap:12px;padding:28px 14px 12px;background:linear-gradient(transparent,rgba(0,0,0,.55));color:#fff;transition:opacity .2s}
.stage.playing:not(:hover) .controls{opacity:0}
.controls button{all:unset;cursor:pointer;display:grid;place-items:center;width:28px;height:28px;border-radius:50%}
.controls button:hover{background:rgba(255,255,255,.14)}
.controls button:focus-visible{outline:2px solid #fff}
.controls svg{width:16px;height:16px;fill:currentColor}
.time{font:600 12px/1 -apple-system,sans-serif;font-variant-numeric:tabular-nums;min-width:84px}
.speed{font:600 12px/1 -apple-system,sans-serif;width:auto!important;padding:0 6px;border-radius:999px!important}
.pill{position:relative;flex:1;height:22px;cursor:pointer;touch-action:none}
.pill .track,.pill .fill{position:absolute;left:0;top:50%;height:4px;margin-top:-2px;border-radius:2px}
.pill .track{right:0;background:rgba(255,255,255,.28)}
.pill .fill{background:var(--accent)}
.pill .head{position:absolute;top:50%;width:12px;height:12px;margin:-6px 0 0 -6px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 2px #fff}
.pill .mark{position:absolute;top:50%;width:2px;height:8px;margin-top:-4px;background:rgba(255,255,255,.7)}
@media (prefers-reduced-motion:reduce){.controls{transition:none}}
`;
var ICONS = {
  play: `<svg viewBox="0 0 16 16"><path d="M4 2.5v11l9-5.5z"/></svg>`,
  pause: `<svg viewBox="0 0 16 16"><path d="M3.5 2h3v12h-3zM9.5 2h3v12h-3z"/></svg>`,
  cc: `<svg viewBox="0 0 16 16"><path d="M2 3h12a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zm4.6 3.2a2 2 0 1 0 0 3.6l-.4-.9a1 1 0 1 1 0-1.8zm5 0a2 2 0 1 0 0 3.6l-.4-.9a1 1 0 1 1 0-1.8z"/></svg>`,
  full: `<svg viewBox="0 0 16 16"><path d="M2 2h4v1.5H3.5V6H2zm8 0h4v4h-1.5V3.5H10zM2 10h1.5v2.5H6V14H2zm10.5 0H14v4h-4v-1.5h2.5z"/></svg>`
};
function player(video) {
  const poster = video.has_thumbnail ? `poster="/v/${video.id}/thumbnail?v=${video.size_bytes}"` : "";
  const captions = video.captions ? `<track kind="captions" srclang="fr" label="Fran\xE7ais" src="/v/${video.id}/captions.vtt">` : "";
  return `
  <div class="stage" id="stage">
    <video id="video" playsinline preload="metadata" ${poster}>
      <source src="/v/${video.id}/video?v=${video.size_bytes}" type="video/mp4">${captions}
    </video>
    <div id="overlay" class="overlay"></div>
    <div class="controls">
      <button id="play" aria-label="Lecture">${ICONS.play}</button>
      <div class="pill" id="pill" role="slider" aria-label="Position" tabindex="0"><span class="track"></span><span class="fill" id="fill"></span><span id="marks"></span><span class="head" id="head"></span></div>
      <span class="time" id="time">0:00 / 0:00</span>
      <button class="speed" id="speed" aria-label="Vitesse">1\xD7</button>
      ${video.captions ? `<button id="cc" aria-label="Sous-titres">${ICONS.cc}</button>` : ""}
      <button id="full" aria-label="Plein \xE9cran">${ICONS.full}</button>
    </div>
  </div>`;
}
__name(player, "player");
var HEAD = /* @__PURE__ */ __name((title) => `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHTML(title)}</title>`, "HEAD");
function playerPage(video, settings, embed) {
  const data = {
    id: video.id,
    duration: video.duration,
    createdAt: video.created_at,
    chapters: JSON.parse(video.chapters || "[]"),
    links: JSON.parse(video.links || "[]"),
    cta: video.cta ? JSON.parse(video.cta) : null
  };
  if (embed) {
    return `${HEAD(video.title)}<style>${BASE_CSS}body{background:#000}.stage{border-radius:0}.stage video{height:100vh;aspect-ratio:auto}${PLAYER_CSS}</style>
<style>:root{--accent:${settings.playerColor}}</style></head><body>${player(video)}
<script>const REEL=${inlineJSON(data)};${PLAYER_JS}<\/script></body></html>`;
  }
  return `${HEAD(video.title)}
<meta property="og:title" content="${escapeHTML(video.title)}">
${video.has_thumbnail ? `<meta property="og:image" content="/v/${video.id}/thumbnail?v=${video.size_bytes}">` : ""}
<style>${BASE_CSS}${PLAYER_CSS}
header{display:flex;align-items:center;justify-content:space-between;gap:16px;min-height:60px;padding:14px max(20px,env(safe-area-inset-right)) 14px max(20px,env(safe-area-inset-left))}
.badge{font-size:12px;color:var(--muted);border:1px solid var(--line);border-radius:999px;padding:3px 10px}
main{max-width:1200px;margin:0 auto;padding:8px max(20px,env(safe-area-inset-left)) 40px;display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:28px}
@media (max-width:900px){main{grid-template-columns:1fr}}
h1{font-family:var(--display);font-size:24px;line-height:1.2;margin:0 0 4px;letter-spacing:-.015em;font-weight:600;text-wrap:balance}
.meta{color:var(--muted);font-size:13px}
.below{display:flex;flex-wrap:wrap;align-items:flex-start;justify-content:space-between;gap:16px;margin-top:18px}
.reactions{display:flex;gap:6px;flex-wrap:wrap}
.reactions button{border:1px solid var(--line);background:var(--surface);border-radius:999px;padding:4px 10px;cursor:pointer;font-size:13px}
.reactions button:hover{border-color:var(--accent)}
.cta{display:inline-block;margin-top:16px;background:var(--accent);color:var(--on-accent);border-radius:10px;padding:10px 18px;text-decoration:none;font-weight:600}
.description{max-width:65ch;color:var(--fg)}
aside{display:grid;gap:16px;align-content:start}
.panel{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:16px}
.panel h2{font-family:var(--display);font-size:13px;font-weight:600;letter-spacing:.02em;color:var(--muted);margin:0 0 10px}
.chapters{list-style:none;margin:0;padding:0;display:grid;gap:2px}
.chapters button{all:unset;cursor:pointer;display:flex;gap:10px;padding:6px 8px;border-radius:8px;width:calc(100% - 16px)}
.chapters button:hover,.chapters button.on{background:color-mix(in srgb,var(--accent) 13%,transparent)}
.t{font-variant-numeric:tabular-nums;color:var(--accent);font-size:13px;min-width:38px;text-decoration:none}
.comments{display:grid;gap:14px;margin:0 0 14px;padding:0;list-style:none;max-height:440px;overflow:auto}
.comments b{font-weight:600}.comments p{margin:2px 0 0}
.empty{color:var(--muted);font-size:13px;margin:0 0 12px}
form{display:grid;gap:8px}
input,textarea{width:100%;border:1px solid var(--line);background:var(--inset);border-radius:10px;padding:9px 11px}
textarea{min-height:68px;resize:vertical}
form button{justify-self:start;background:var(--accent);color:var(--on-accent);border:0;border-radius:10px;padding:8px 16px;font-weight:600;cursor:pointer}
.hint{font-size:12px;color:var(--muted);display:flex;align-items:center;gap:6px}
.hint input{width:auto;accent-color:var(--accent)}
.error{color:#c0362c;font-size:13px}
</style><style>:root{--accent:${settings.playerColor}}</style></head><body>
<header>${brand(settings)}${video.privacy === "password" ? `<span class="badge">Prot\xE9g\xE9e par mot de passe</span>` : ""}</header>
<main>
  <section>
    ${player(video)}
    <div class="below">
      <div>
        <h1>${escapeHTML(video.title)}</h1>
        <div class="meta" id="meta"></div>
      </div>
      <div class="reactions" id="reactions" aria-label="R\xE9agir">
        <button data-kind="thumbs" aria-label="Utile">\u{1F44D} <span></span></button><button data-kind="heart" aria-label="J'adore">\u2764\uFE0F <span></span></button><button data-kind="clap" aria-label="Bravo">\u{1F44F} <span></span></button><button data-kind="laugh" aria-label="Dr\xF4le">\u{1F604} <span></span></button><button data-kind="wow" aria-label="Surprenant">\u{1F62E} <span></span></button>
      </div>
    </div>
    ${data.cta ? `<a class="cta" href="${escapeHTML(data.cta.url)}" target="_blank" rel="noopener">${escapeHTML(data.cta.label)}</a>` : ""}
    ${video.description ? `<p class="description">${escapeHTML(video.description)}</p>` : ""}
  </section>
  <aside>
    ${data.chapters.length ? `<div class="panel"><h2>Chapitres</h2><ul class="chapters" id="chapters"></ul></div>` : ""}
    <div class="panel">
      <h2>Commentaires</h2>
      <ul class="comments" id="comments"></ul>
      <p class="empty" id="no-comments">Sois le premier \xE0 r\xE9agir.</p>
      <form id="comment-form">
        <input id="comment-author" name="author" placeholder="Ton nom" autocomplete="name" required maxlength="60">
        <textarea id="comment-body" name="body" placeholder="Ton commentaire" required maxlength="2000"></textarea>
        <label class="hint"><input type="checkbox" id="comment-at" checked> Au moment <span id="comment-time">0:00</span></label>
        <button type="submit">Commenter</button>
        <span class="error" id="comment-error" hidden></span>
      </form>
    </div>
  </aside>
</main>
<script>const REEL=${inlineJSON(data)};${PLAYER_JS}${PAGE_JS}<\/script>
</body></html>`;
}
__name(playerPage, "playerPage");
function passwordPage(video, settings, wrong, embed) {
  return `${HEAD("Vid\xE9o prot\xE9g\xE9e")}<meta name="robots" content="noindex"><style>${BASE_CSS}
body{min-height:100vh;display:grid;place-items:center;padding:16px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:26px;width:min(380px,100%);display:grid;gap:12px}
h1{font-family:var(--display);font-size:19px;font-weight:600;margin:0;letter-spacing:-.01em}p{margin:0;color:var(--muted)}
input{border:1px solid var(--line);background:var(--inset);border-radius:10px;padding:10px 11px;width:100%}
button{background:var(--accent);color:var(--on-accent);border:0;border-radius:10px;padding:10px 14px;font-weight:600;cursor:pointer}
.error{color:#c0362c;font-size:13px}</style><style>:root{--accent:${settings.playerColor}}</style></head><body>
<form class="card" method="post" action="/${embed ? "embed" : "v"}/${video.id}/unlock">
  ${brand(settings)}
  <h1>${escapeHTML(video.title)}</h1>
  <p>Cette vid\xE9o est prot\xE9g\xE9e par un mot de passe.</p>
  <input id="password" type="password" name="password" placeholder="Mot de passe" autocomplete="current-password" required autofocus>
  ${wrong ? `<span class="error">Mot de passe incorrect. R\xE9essaie ou demande-le \xE0 l'auteur.</span>` : ""}
  <button type="submit">Regarder</button>
</form></body></html>`;
}
__name(passwordPage, "passwordPage");
var PLAYER_JS = `
const video=document.getElementById("video"),stage=document.getElementById("stage"),overlay=document.getElementById("overlay");
const pill=document.getElementById("pill"),fill=document.getElementById("fill"),head=document.getElementById("head"),timeEl=document.getElementById("time");
const playBtn=document.getElementById("play");const ICON_PLAY=${JSON.stringify(ICONS.play)},ICON_PAUSE=${JSON.stringify(ICONS.pause)};
const fmt=s=>{s=Math.max(0,Math.floor(s||0));return Math.floor(s/60)+":"+String(s%60).padStart(2,"0")};
const dur=()=>video.duration&&isFinite(video.duration)?video.duration:REEL.duration;
function paint(){const d=dur()||1,p=Math.min(1,video.currentTime/d)*100;fill.style.width=p+"%";head.style.left=p+"%";timeEl.textContent=fmt(video.currentTime)+" / "+fmt(dur());pill.setAttribute("aria-valuenow",Math.round(p))}
function toggle(){video.paused?video.play():video.pause()}
playBtn.onclick=toggle;video.onclick=toggle;
video.addEventListener("play",()=>{stage.classList.add("playing");playBtn.innerHTML=ICON_PAUSE});
video.addEventListener("pause",()=>{stage.classList.remove("playing");playBtn.innerHTML=ICON_PLAY});
video.addEventListener("timeupdate",paint);video.addEventListener("loadedmetadata",()=>{paint();drawMarks()});
function seekAt(x){const r=pill.getBoundingClientRect();video.currentTime=Math.min(1,Math.max(0,(x-r.left)/r.width))*dur();paint()}
pill.addEventListener("pointerdown",e=>{pill.setPointerCapture(e.pointerId);seekAt(e.clientX);pill.onpointermove=m=>seekAt(m.clientX)});
pill.addEventListener("pointerup",()=>{pill.onpointermove=null});
pill.addEventListener("keydown",e=>{if(e.key==="ArrowRight")video.currentTime+=5;if(e.key==="ArrowLeft")video.currentTime-=5});
function drawMarks(){const m=document.getElementById("marks");m.replaceChildren(...REEL.chapters.filter(c=>c.time>0).map(c=>{const s=document.createElement("span");s.className="mark";s.style.left=(c.time/(dur()||1)*100)+"%";return s}))}
const speeds=[1,1.25,1.5,2],speedBtn=document.getElementById("speed");let si=0;
speedBtn.onclick=()=>{si=(si+1)%speeds.length;video.playbackRate=speeds[si];speedBtn.textContent=speeds[si]+"\xD7"};
const cc=document.getElementById("cc");if(cc){const tr=()=>video.textTracks[0];cc.onclick=()=>{const t=tr();if(t)t.mode=t.mode==="showing"?"hidden":"showing";cc.style.opacity=t&&t.mode==="showing"?1:.6};cc.style.opacity=.6}
document.getElementById("full").onclick=()=>{document.fullscreenElement?document.exitFullscreen():stage.requestFullscreen&&stage.requestFullscreen()};
document.addEventListener("keydown",e=>{if(e.target.closest&&e.target.closest("input,textarea"))return;if(e.code==="Space"){e.preventDefault();toggle()}});
let shown="";
video.addEventListener("timeupdate",()=>{const t=video.currentTime;const active=REEL.links.filter(l=>t>=l.start&&t<=l.end);
const key=active.map(l=>l.url).join("|");if(key===shown)return;shown=key;overlay.replaceChildren(...active.map(l=>{const a=document.createElement("a");a.href=l.url;a.target="_blank";a.rel="noopener";a.textContent=l.label;return a}))});
const viewId=crypto.randomUUID();let best=0;let viewer="";try{viewer=localStorage.getItem("reel-name")||""}catch(e){}
function report(){const d=dur();if(!d)return;const p=Math.min(100,Math.round(video.currentTime/d*100));if(p<=best&&best>0)return;best=Math.max(best,p);
navigator.sendBeacon("/v/"+REEL.id+"/views",new Blob([JSON.stringify({view:viewId,viewer,percent:best})],{type:"application/json"}))}
video.addEventListener("play",report,{once:true});setInterval(()=>{if(!video.paused)report()},10000);
video.addEventListener("ended",report);addEventListener("pagehide",report);paint();
`;
var PAGE_JS = `
const meta=document.getElementById("meta");meta.textContent=new Date(REEL.createdAt).toLocaleDateString("fr-FR",{day:"numeric",month:"long",year:"numeric"})+(REEL.duration?" \xB7 "+fmt(REEL.duration):"");
const list=document.getElementById("chapters");
if(list){for(const c of REEL.chapters){const li=document.createElement("li");const b=document.createElement("button");b.innerHTML='<span class="t"></span><span></span>';
b.children[0].textContent=fmt(c.time);b.children[1].textContent=c.title;b.onclick=()=>{video.currentTime=c.time;video.play()};li.append(b);list.append(li)}
video.addEventListener("timeupdate",()=>{const t=video.currentTime;let i=-1;REEL.chapters.forEach((c,k)=>{if(t>=c.time)i=k});[...list.querySelectorAll("button")].forEach((b,k)=>b.classList.toggle("on",k===i))})}
const timeLabel=document.getElementById("comment-time");video.addEventListener("timeupdate",()=>timeLabel.textContent=fmt(video.currentTime));
const author=document.getElementById("comment-author");try{author.value=localStorage.getItem("reel-name")||""}catch(e){}
async function loadComments(){const r=await fetch("/v/"+REEL.id+"/comments");if(!r.ok)return;const {comments}=await r.json();const ul=document.getElementById("comments");
document.getElementById("no-comments").hidden=comments.length>0;
ul.replaceChildren(...comments.map(c=>{const li=document.createElement("li");const head=document.createElement("div");const b=document.createElement("b");b.textContent=c.author;head.append(b);
if(c.time!==null){const t=document.createElement("a");t.href="#";t.className="t";t.textContent=" "+fmt(c.time);t.onclick=e=>{e.preventDefault();video.currentTime=c.time;video.play()};head.append(t)}
const p=document.createElement("p");p.textContent=c.body;li.append(head,p);return li}))}
document.getElementById("comment-form").addEventListener("submit",async e=>{e.preventDefault();const err=document.getElementById("comment-error");err.hidden=true;
const body={author:author.value,body:document.getElementById("comment-body").value,time:document.getElementById("comment-at").checked?video.currentTime:""};
try{localStorage.setItem("reel-name",author.value)}catch(x){}
const r=await fetch("/v/"+REEL.id+"/comments",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});
if(!r.ok){err.textContent=(await r.json().catch(()=>({}))).error||"Le commentaire n'est pas parti. R\xE9essaie.";err.hidden=false;return}
document.getElementById("comment-body").value="";loadComments()});
async function loadReactions(){const r=await fetch("/v/"+REEL.id+"/reactions");if(!r.ok)return;const {reactions}=await r.json();
for(const b of document.querySelectorAll("#reactions button")){const n=reactions.find(x=>x.kind===b.dataset.kind);b.querySelector("span").textContent=n?n.count:""}}
for(const b of document.querySelectorAll("#reactions button"))b.onclick=async()=>{await fetch("/v/"+REEL.id+"/reactions",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({kind:b.dataset.kind,time:video.currentTime})});loadReactions()};
loadComments();loadReactions();
`;

// src/viewer.ts
var REACTIONS = /* @__PURE__ */ new Set(["thumbs", "heart", "laugh", "wow", "clap"]);
async function readyVideo(env, id) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ? AND status = 'ready'").bind(id).first();
  if (!row) throw new HttpError(404, "Cette vid\xE9o n'existe pas ou a \xE9t\xE9 supprim\xE9e.");
  return row;
}
__name(readyVideo, "readyVideo");
function cookie(request, name) {
  const header = request.headers.get("Cookie") ?? "";
  for (const part of header.split(";")) {
    const [key, ...value] = part.trim().split("=");
    if (key === name) return value.join("=");
  }
  return null;
}
__name(cookie, "cookie");
var cookieName = /* @__PURE__ */ __name((id) => `reel_${id}`, "cookieName");
async function hasAccess(request, env, video) {
  if (video.privacy !== "password" || !video.password_hash) return true;
  const provided = cookie(request, cookieName(video.id));
  if (!provided) return false;
  return safeEqual(provided, await accessToken(env.SIGNING_KEY, video.id, video.password_hash));
}
__name(hasAccess, "hasAccess");
async function requireAccess(request, env, video) {
  if (!await hasAccess(request, env, video)) throw new HttpError(401, "Mot de passe requis.");
}
__name(requireAccess, "requireAccess");
async function streamObject(request, env, key, cacheSeconds) {
  try {
    await spendOps(env, "read");
  } catch (error) {
    if (error instanceof QuotaError) return new Response(error.message, { status: 429 });
    throw error;
  }
  const object = await env.VIDEOS.get(key, { range: request.headers, onlyIf: request.headers });
  if (!object) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Accept-Ranges", "bytes");
  headers.set("Cache-Control", `private, max-age=${cacheSeconds}`);
  if (!("body" in object)) return new Response(null, { status: 304, headers });
  const range = object.range;
  if (range && request.headers.has("Range")) {
    const offset = range.suffix !== void 0 ? object.size - range.suffix : range.offset ?? 0;
    const length = range.suffix ?? range.length ?? object.size - offset;
    headers.set("Content-Range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("Content-Length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("Content-Length", String(object.size));
  return new Response(object.body, { headers });
}
__name(streamObject, "streamObject");
async function form(request) {
  const type = request.headers.get("Content-Type") ?? "";
  if (type.includes("application/json")) return await request.json();
  const data = await request.formData();
  return Object.fromEntries([...data.entries()].map(([key, value]) => [key, String(value)]));
}
__name(form, "form");
async function handleViewer(request, env, path, embed) {
  const [id, action] = path;
  if (!id) throw new HttpError(404, "Not found.");
  const video = await readyVideo(env, id);
  const method = request.method;
  if (action === "unlock" && method === "POST") {
    const { password = "" } = await form(request);
    const location = new URL(request.url);
    location.pathname = `/${embed ? "embed" : "v"}/${id}`;
    if (!video.password_hash || !await verifyPassword(password, video.password_hash)) {
      location.searchParams.set("wrong", "1");
      return Response.redirect(location.toString(), 303);
    }
    const token = await accessToken(env.SIGNING_KEY, id, video.password_hash);
    return new Response(null, {
      status: 303,
      headers: {
        Location: location.toString(),
        "Set-Cookie": `${cookieName(id)}=${token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000`
      }
    });
  }
  if (!action && method === "GET") {
    const settings = await getSettings(env);
    const html = await hasAccess(request, env, video) ? playerPage(video, settings, embed) : passwordPage(video, settings, new URL(request.url).searchParams.has("wrong"), embed);
    return new Response(html, {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Robots-Tag": video.privacy === "public" ? "all" : "noindex",
        "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; media-src 'self'; frame-ancestors *",
        "Referrer-Policy": "same-origin"
      }
    });
  }
  if (method === "GET" && (action === "video" || action === "thumbnail" || action === "preview" || action === "captions.vtt")) {
    await requireAccess(request, env, video);
    if (action === "video") return streamObject(request, env, videoKey(id), 3600);
    if (action === "thumbnail") return streamObject(request, env, `videos/${id}/thumbnail.jpg`, 86400);
    if (action === "preview") return streamObject(request, env, `videos/${id}/preview.gif`, 86400);
    return new Response(video.captions ?? "WEBVTT\n", { headers: { "Content-Type": "text/vtt; charset=utf-8" } });
  }
  if (action === "comments") {
    await requireAccess(request, env, video);
    if (method === "GET") {
      const { results } = await env.DB.prepare("SELECT id, author, body, time, created_at FROM comments WHERE video_id = ? ORDER BY created_at").bind(id).all();
      return Response.json({ comments: results });
    }
    if (method === "POST") {
      const body = await form(request);
      const author = (body.author ?? "").trim().slice(0, 60);
      const text = (body.body ?? "").trim().slice(0, 2e3);
      if (!author || !text) throw new HttpError(400, "Indique ton nom et ton commentaire.");
      const time = body.time === void 0 || body.time === "" ? null : Math.max(0, Number(body.time) || 0);
      await env.DB.prepare("INSERT INTO comments (video_id, author, body, time) VALUES (?, ?, ?, ?)").bind(id, author, text, time).run();
      return Response.json({ ok: true }, { status: 201 });
    }
  }
  if (action === "reactions" && method === "POST") {
    await requireAccess(request, env, video);
    const body = await form(request);
    if (!REACTIONS.has(body.kind)) throw new HttpError(400, "R\xE9action inconnue.");
    await env.DB.prepare("INSERT INTO reactions (video_id, kind, time) VALUES (?, ?, ?)").bind(id, body.kind, body.time ? Number(body.time) || 0 : null).run();
    return Response.json({ ok: true }, { status: 201 });
  }
  if (action === "reactions" && method === "GET") {
    await requireAccess(request, env, video);
    const { results } = await env.DB.prepare("SELECT kind, COUNT(*) AS count FROM reactions WHERE video_id = ? GROUP BY kind").bind(id).all();
    return Response.json({ reactions: results });
  }
  if (action === "views" && method === "POST") {
    await requireAccess(request, env, video);
    const body = await form(request);
    const viewId = String(body.view ?? "");
    if (!/^[0-9a-f-]{36}$/.test(viewId)) throw new HttpError(400, "Invalid view id.");
    const percent = Math.min(100, Math.max(0, Number(body.percent) || 0));
    const viewer = body.viewer ? String(body.viewer).slice(0, 60) : null;
    await env.DB.prepare(
      `INSERT INTO views (id, video_id, viewer, percent) VALUES (?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET percent = MAX(views.percent, excluded.percent),
         viewer = COALESCE(excluded.viewer, views.viewer),
         updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
       WHERE views.video_id = excluded.video_id`
    ).bind(viewId, id, viewer, percent).run();
    return new Response(null, { status: 204 });
  }
  throw new HttpError(404, "Not found.");
}
__name(handleViewer, "handleViewer");
async function brandLogo(request, env) {
  return streamObject(request, env, "brand/logo", 86400);
}
__name(brandLogo, "brandLogo");

// src/index.ts
var index_default = {
  async fetch(request, env) {
    const url = new URL(request.url);
    const [root, ...path] = url.pathname.split("/").filter(Boolean);
    try {
      if (root === "api") {
        if (path[0] === "health") return Response.json({ ok: true });
        if (!await isOwner(request, env)) throw new HttpError(401, "Invalid owner token.");
        return await handleOwner(request, env, path);
      }
      if (root === "v") return await handleViewer(request, env, path, false);
      if (root === "embed") return await handleViewer(request, env, path, true);
      if (root === "brand" && path[0] === "logo") return await brandLogo(request, env);
      if (root === "fonts" && path[0] === "InstrumentSans.ttf") {
        const font = await env.VIDEOS.get("public/fonts/InstrumentSans.ttf");
        if (!font) return new Response("Not found", { status: 404 });
        return new Response(font.body, { headers: { "Content-Type": "font/ttf", "Cache-Control": "public, max-age=31536000, immutable" } });
      }
      if (!root) return new Response("Reel", { headers: { "Content-Type": "text/plain; charset=utf-8" } });
      throw new HttpError(404, "Not found.");
    } catch (error) {
      if (error instanceof HttpError) return Response.json({ error: error.message }, { status: error.status });
      if (error instanceof QuotaError) return Response.json({ error: error.message, quota: error.reason }, { status: 429 });
      const message = error instanceof Error ? error.message : "Unknown error";
      console.error(JSON.stringify({ message: "unhandled error", error: message, path: url.pathname }));
      return Response.json({ error: "Internal server error" }, { status: 500 });
    }
  }
};
export {
  index_default as default
};
//# sourceMappingURL=index.js.map
