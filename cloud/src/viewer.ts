// Public side: the share page, the embed player, the video stream and viewer interactions.

import { accessToken, safeEqual, verifyPassword } from "./crypto";
import { HttpError, videoKey } from "./api";
import { QuotaError, spendOps } from "./quota";
import { getSettings, type VideoRow } from "./store";
import { passwordPage, playerPage } from "./page";

const REACTIONS = new Set(["thumbs", "heart", "laugh", "wow", "clap"]);

async function readyVideo(env: Env, id: string): Promise<VideoRow> {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ? AND status = 'ready'").bind(id).first<VideoRow>();
  if (!row) throw new HttpError(404, "Cette vidéo n'existe pas ou a été supprimée.");
  return row;
}

function cookie(request: Request, name: string): string | null {
  const header = request.headers.get("Cookie") ?? "";
  for (const part of header.split(";")) {
    const [key, ...value] = part.trim().split("=");
    if (key === name) return value.join("=");
  }
  return null;
}

const cookieName = (id: string) => `reel_${id}`;

async function hasAccess(request: Request, env: Env, video: VideoRow): Promise<boolean> {
  if (video.privacy !== "password" || !video.password_hash) return true;
  const provided = cookie(request, cookieName(video.id));
  if (!provided) return false;
  return safeEqual(provided, await accessToken(env.SIGNING_KEY, video.id, video.password_hash));
}

async function requireAccess(request: Request, env: Env, video: VideoRow): Promise<void> {
  if (!(await hasAccess(request, env, video))) throw new HttpError(401, "Mot de passe requis.");
}

/** Range-aware stream of an R2 object. Each request counts as one R2 read. */
async function streamObject(request: Request, env: Env, key: string, cacheSeconds: number): Promise<Response> {
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

  const range = object.range as { offset?: number; length?: number; suffix?: number } | undefined;
  if (range && request.headers.has("Range")) {
    const offset = range.suffix !== undefined ? object.size - range.suffix : range.offset ?? 0;
    const length = range.suffix ?? range.length ?? object.size - offset;
    headers.set("Content-Range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("Content-Length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("Content-Length", String(object.size));
  return new Response(object.body, { headers });
}

async function form(request: Request): Promise<Record<string, string>> {
  const type = request.headers.get("Content-Type") ?? "";
  if (type.includes("application/json")) return (await request.json()) as Record<string, string>;
  const data = await request.formData();
  return Object.fromEntries([...data.entries()].map(([key, value]) => [key, String(value)]));
}

export async function handleViewer(request: Request, env: Env, path: string[], embed: boolean): Promise<Response> {
  const [id, action] = path;
  if (!id) throw new HttpError(404, "Not found.");
  const video = await readyVideo(env, id);
  const method = request.method;

  // POST /v/:id/unlock (password form)
  if (action === "unlock" && method === "POST") {
    const { password = "" } = await form(request);
    const location = new URL(request.url);
    location.pathname = `/${embed ? "embed" : "v"}/${id}`;
    if (!video.password_hash || !(await verifyPassword(password, video.password_hash))) {
      location.searchParams.set("wrong", "1");
      return Response.redirect(location.toString(), 303);
    }
    const token = await accessToken(env.SIGNING_KEY, id, video.password_hash);
    return new Response(null, {
      status: 303,
      headers: {
        Location: location.toString(),
        "Set-Cookie": `${cookieName(id)}=${token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000`,
      },
    });
  }

  // GET /v/:id
  if (!action && method === "GET") {
    const settings = await getSettings(env);
    const html = (await hasAccess(request, env, video))
      ? playerPage(video, settings, embed)
      : passwordPage(video, settings, new URL(request.url).searchParams.has("wrong"), embed);
    return new Response(html, {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Robots-Tag": video.privacy === "public" ? "all" : "noindex",
        "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; media-src 'self'; frame-ancestors *",
        "Referrer-Policy": "same-origin",
      },
    });
  }

  if (method === "GET" && (action === "video" || action === "thumbnail" || action === "preview" || action === "captions.vtt")) {
    await requireAccess(request, env, video);
    if (action === "video") return streamObject(request, env, videoKey(id), 3600);
    if (action === "thumbnail") return streamObject(request, env, `videos/${id}/thumbnail.jpg`, 86400);
    if (action === "preview") return streamObject(request, env, `videos/${id}/preview.gif`, 86400);
    return new Response(video.captions ?? "WEBVTT\n", { headers: { "Content-Type": "text/vtt; charset=utf-8" } });
  }

  // GET | POST /v/:id/comments
  if (action === "comments") {
    await requireAccess(request, env, video);
    if (method === "GET") {
      const { results } = await env.DB.prepare("SELECT id, author, body, time, created_at FROM comments WHERE video_id = ? ORDER BY created_at")
        .bind(id)
        .all();
      return Response.json({ comments: results });
    }
    if (method === "POST") {
      const body = await form(request);
      const author = (body.author ?? "").trim().slice(0, 60);
      const text = (body.body ?? "").trim().slice(0, 2000);
      if (!author || !text) throw new HttpError(400, "Indique ton nom et ton commentaire.");
      const time = body.time === undefined || body.time === "" ? null : Math.max(0, Number(body.time) || 0);
      await env.DB.prepare("INSERT INTO comments (video_id, author, body, time) VALUES (?, ?, ?, ?)").bind(id, author, text, time).run();
      return Response.json({ ok: true }, { status: 201 });
    }
  }

  // POST /v/:id/reactions { kind, time }
  if (action === "reactions" && method === "POST") {
    await requireAccess(request, env, video);
    const body = await form(request);
    if (!REACTIONS.has(body.kind)) throw new HttpError(400, "Réaction inconnue.");
    await env.DB.prepare("INSERT INTO reactions (video_id, kind, time) VALUES (?, ?, ?)")
      .bind(id, body.kind, body.time ? Number(body.time) || 0 : null)
      .run();
    return Response.json({ ok: true }, { status: 201 });
  }

  // GET /v/:id/reactions
  if (action === "reactions" && method === "GET") {
    await requireAccess(request, env, video);
    const { results } = await env.DB.prepare("SELECT kind, COUNT(*) AS count FROM reactions WHERE video_id = ? GROUP BY kind").bind(id).all();
    return Response.json({ reactions: results });
  }

  // POST /v/:id/views { view, viewer, percent } — one row per viewing session, percent only grows.
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
       WHERE views.video_id = excluded.video_id`,
    )
      .bind(viewId, id, viewer, percent)
      .run();
    return new Response(null, { status: 204 });
  }

  throw new HttpError(404, "Not found.");
}

/** GET /brand/logo — the workspace logo, public. */
export async function brandLogo(request: Request, env: Env): Promise<Response> {
  return streamObject(request, env, "brand/logo", 86400);
}
