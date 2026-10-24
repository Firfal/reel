// Reel sharing server: one Worker, one R2 bucket, one D1 database, all in the user's own Cloudflare account.
//
//   /api/*            owner API for the Mac app (Bearer OWNER_TOKEN)
//   /v/:id[/...]      share page, video stream, comments, reactions, views
//   /embed/:id        bare player for <iframe>
//   /brand/logo       workspace logo

import { handleOwner, HttpError, isOwner } from "./api";
import { QuotaError } from "./quota";
import { brandLogo, handleViewer } from "./viewer";

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    const [root, ...path] = url.pathname.split("/").filter(Boolean);
    try {
      if (root === "api") {
        if (path[0] === "health") return Response.json({ ok: true });
        if (!(await isOwner(request, env))) throw new HttpError(401, "Invalid owner token.");
        return await handleOwner(request, env, path);
      }
      if (root === "v") return await handleViewer(request, env, path, false);
      if (root === "embed") return await handleViewer(request, env, path, true);
      if (root === "brand" && path[0] === "logo") return await brandLogo(request, env);
      if (!root) return new Response("Reel", { headers: { "Content-Type": "text/plain; charset=utf-8" } });
      throw new HttpError(404, "Not found.");
    } catch (error) {
      if (error instanceof HttpError) return Response.json({ error: error.message }, { status: error.status });
      if (error instanceof QuotaError) return Response.json({ error: error.message, quota: error.reason }, { status: 429 });
      const message = error instanceof Error ? error.message : "Unknown error";
      console.error(JSON.stringify({ message: "unhandled error", error: message, path: url.pathname }));
      return Response.json({ error: "Internal server error" }, { status: 500 });
    }
  },
} satisfies ExportedHandler<Env>;
