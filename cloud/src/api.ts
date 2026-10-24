// Owner API, called by the Mac app with `Authorization: Bearer <OWNER_TOKEN>`.

import { hashPassword, newSlug, safeEqual } from "./crypto";
import { assertStorageFor, spendOps, usageSummary } from "./quota";
import { getSettings, putSettings, type VideoRow } from "./store";

/** Parts are streamed through the Worker, whose request body limit is 100 MB on the free plan. */
export const PART_SIZE = 50 * 1024 * 1024;
const MAX_PART_BYTES = 95 * 1024 * 1024;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const PRIVACIES = new Set(["public", "unlisted", "password"]);

export class HttpError extends Error {
  constructor(public readonly status: number, message: string) {
    super(message);
  }
}

export function videoKey(id: string): string {
  return `videos/${id}/video.mp4`;
}

export async function isOwner(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  return token.length > 0 && safeEqual(token, env.OWNER_TOKEN);
}

async function readJSON<T>(request: Request): Promise<T> {
  try {
    return (await request.json()) as T;
  } catch {
    throw new HttpError(400, "Body must be JSON.");
  }
}

async function loadVideo(env: Env, id: string): Promise<VideoRow> {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first<VideoRow>();
  if (!row) throw new HttpError(404, "Video not found.");
  return row;
}

function contentLength(request: Request, max: number): number {
  const length = Number(request.headers.get("Content-Length"));
  if (!Number.isFinite(length) || length <= 0) throw new HttpError(411, "Content-Length is required.");
  if (length > max) throw new HttpError(413, `Body too large (max ${max} bytes).`);
  return length;
}

type Metadata = {
  title?: string;
  description?: string;
  duration?: number;
  privacy?: string;
  password?: string;
  chapters?: { time: number; title: string }[];
  cta?: { label: string; url: string } | null;
  links?: { start: number; end: number; label: string; url: string }[];
  captions?: string | null;
};

/** Builds the SQL assignments for the fields present in `body`. */
async function metadataUpdates(body: Metadata): Promise<[string[], unknown[]]> {
  const columns: string[] = [];
  const values: unknown[] = [];
  const set = (column: string, value: unknown) => {
    columns.push(`${column} = ?`);
    values.push(value);
  };
  if (body.title !== undefined) set("title", String(body.title).slice(0, 200));
  if (body.description !== undefined) set("description", String(body.description).slice(0, 5000));
  if (body.duration !== undefined) set("duration", Number(body.duration) || 0);
  if (body.privacy !== undefined) {
    if (!PRIVACIES.has(body.privacy)) throw new HttpError(400, "privacy must be public, unlisted or password.");
    set("privacy", body.privacy);
  }
  if (body.password !== undefined) set("password_hash", body.password ? await hashPassword(body.password) : null);
  if (body.chapters !== undefined) set("chapters", JSON.stringify(body.chapters ?? []));
  if (body.cta !== undefined) set("cta", body.cta ? JSON.stringify(body.cta) : null);
  if (body.links !== undefined) set("links", JSON.stringify(body.links ?? []));
  if (body.captions !== undefined) set("captions", body.captions);
  return [columns, values];
}

export async function handleOwner(request: Request, env: Env, path: string[]): Promise<Response> {
  const method = request.method;

  // GET /api/usage
  if (path[0] === "usage" && method === "GET") return Response.json(await usageSummary(env));

  // GET | PUT /api/settings
  if (path[0] === "settings") {
    if (method === "GET") return Response.json(await getSettings(env));
    if (method === "PUT") return Response.json(await putSettings(env, await readJSON(request)));
  }

  // PUT /api/fonts/InstrumentSans.ttf — used once by the Mac app's setup
  if (path[0] === "fonts" && path[1] === "InstrumentSans.ttf" && method === "PUT") {
    contentLength(request, MAX_IMAGE_BYTES);
    await spendOps(env, "write");
    await env.VIDEOS.put("public/fonts/InstrumentSans.ttf", request.body, { httpMetadata: { contentType: "font/ttf" } });
    return Response.json({ ok: true });
  }

  // PUT /api/brand/logo (image body)
  if (path[0] === "brand" && path[1] === "logo" && method === "PUT") {
    const length = contentLength(request, MAX_IMAGE_BYTES);
    await spendOps(env, "write");
    await env.VIDEOS.put("brand/logo", request.body, {
      httpMetadata: { contentType: request.headers.get("Content-Type") ?? "image/png" },
    });
    await putSettings(env, { hasLogo: true, logoVersion: Date.now() });
    return Response.json({ ok: true, bytes: length });
  }

  if (path[0] !== "videos") throw new HttpError(404, "Not found.");
  const id = path[1];

  // GET /api/videos
  if (!id && method === "GET") {
    const { results } = await env.DB.prepare(
      `SELECT v.id, v.title, v.duration, v.size_bytes, v.status, v.privacy, v.created_at,
              (SELECT COUNT(*) FROM views w WHERE w.video_id = v.id) AS views,
              (SELECT COUNT(*) FROM comments c WHERE c.video_id = v.id) AS comments
       FROM videos v ORDER BY v.created_at DESC`,
    ).all();
    return Response.json({ videos: results });
  }

  // POST /api/videos { sizeBytes, ...metadata } -> starts a multipart upload
  if (!id && method === "POST") {
    const body = await readJSON<Metadata & { sizeBytes: number }>(request);
    const sizeBytes = Number(body.sizeBytes);
    if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) throw new HttpError(400, "sizeBytes is required.");
    await assertStorageFor(env, sizeBytes);
    await spendOps(env, "write");
    const slug = newSlug();
    const upload = await env.VIDEOS.createMultipartUpload(videoKey(slug), { httpMetadata: { contentType: "video/mp4" } });
    await env.DB.prepare("INSERT INTO videos (id, title, size_bytes, upload_id) VALUES (?, ?, ?, ?)")
      .bind(slug, body.title?.slice(0, 200) || "Vidéo", sizeBytes, upload.uploadId)
      .run();
    const [columns, values] = await metadataUpdates({ ...body, title: undefined });
    if (columns.length) {
      await env.DB.prepare(`UPDATE videos SET ${columns.join(", ")} WHERE id = ?`).bind(...values, slug).run();
    }
    const origin = new URL(request.url).origin;
    return Response.json({ id: slug, partSize: PART_SIZE, url: `${origin}/v/${slug}` }, { status: 201 });
  }

  if (!id) throw new HttpError(405, "Method not allowed.");
  const video = await loadVideo(env, id);

  // PUT /api/videos/:id/parts/:n
  if (path[2] === "parts" && method === "PUT") {
    const partNumber = Number(path[3]);
    if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10_000) throw new HttpError(400, "Invalid part number.");
    if (!video.upload_id || video.status !== "uploading") throw new HttpError(409, "No upload in progress.");
    contentLength(request, MAX_PART_BYTES);
    await spendOps(env, "write");
    const upload = env.VIDEOS.resumeMultipartUpload(videoKey(id), video.upload_id);
    const part = await upload.uploadPart(partNumber, request.body!);
    return Response.json(part);
  }

  // POST /api/videos/:id/complete { parts: [{ partNumber, etag }] }
  if (path[2] === "complete" && method === "POST") {
    if (!video.upload_id) throw new HttpError(409, "No upload in progress.");
    const { parts } = await readJSON<{ parts: R2UploadedPart[] }>(request);
    await spendOps(env, "write");
    const upload = env.VIDEOS.resumeMultipartUpload(videoKey(id), video.upload_id);
    const object = await upload.complete(parts);
    await env.DB.prepare("UPDATE videos SET status = 'ready', upload_id = NULL, size_bytes = ? WHERE id = ?")
      .bind(object.size, id)
      .run();
    return Response.json({ ok: true, size: object.size });
  }

  // PUT /api/videos/:id/thumbnail | /preview (JPEG / GIF body)
  if ((path[2] === "thumbnail" || path[2] === "preview") && method === "PUT") {
    const length = contentLength(request, MAX_IMAGE_BYTES);
    await assertStorageFor(env, length);
    await spendOps(env, "write");
    const isThumbnail = path[2] === "thumbnail";
    await env.VIDEOS.put(`videos/${id}/${isThumbnail ? "thumbnail.jpg" : "preview.gif"}`, request.body, {
      httpMetadata: { contentType: isThumbnail ? "image/jpeg" : "image/gif" },
    });
    await env.DB.prepare(`UPDATE videos SET ${isThumbnail ? "has_thumbnail" : "has_preview"} = 1, size_bytes = size_bytes + ? WHERE id = ?`)
      .bind(length, id)
      .run();
    return Response.json({ ok: true });
  }

  // GET /api/videos/:id/insights
  if (path[2] === "insights" && method === "GET") {
    const [views, comments, reactions] = await Promise.all([
      env.DB.prepare("SELECT viewer, percent, created_at FROM views WHERE video_id = ? ORDER BY created_at DESC LIMIT 500").bind(id).all(),
      env.DB.prepare("SELECT id, author, body, time, created_at FROM comments WHERE video_id = ? ORDER BY created_at").bind(id).all(),
      env.DB.prepare("SELECT kind, COUNT(*) AS count FROM reactions WHERE video_id = ? GROUP BY kind").bind(id).all(),
    ]);
    return Response.json({ views: views.results, comments: comments.results, reactions: reactions.results });
  }

  // PATCH /api/videos/:id
  if (!path[2] && method === "PATCH") {
    const [columns, values] = await metadataUpdates(await readJSON<Metadata>(request));
    if (columns.length) await env.DB.prepare(`UPDATE videos SET ${columns.join(", ")} WHERE id = ?`).bind(...values, id).run();
    return Response.json({ ok: true });
  }

  // DELETE /api/videos/:id — deleting from R2 is free and is not counted.
  if (!path[2] && method === "DELETE") {
    if (video.upload_id) await env.VIDEOS.resumeMultipartUpload(videoKey(id), video.upload_id).abort().catch(() => {});
    await env.VIDEOS.delete([videoKey(id), `videos/${id}/thumbnail.jpg`, `videos/${id}/preview.gif`]);
    await env.DB.batch([
      env.DB.prepare("DELETE FROM comments WHERE video_id = ?").bind(id),
      env.DB.prepare("DELETE FROM reactions WHERE video_id = ?").bind(id),
      env.DB.prepare("DELETE FROM views WHERE video_id = ?").bind(id),
      env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(id),
    ]);
    return Response.json({ ok: true });
  }

  throw new HttpError(405, "Method not allowed.");
}
