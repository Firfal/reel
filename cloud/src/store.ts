// Rows and workspace settings shared by the owner API and the viewer pages.

export type VideoRow = {
  id: string;
  title: string;
  description: string;
  duration: number;
  size_bytes: number;
  status: "uploading" | "ready";
  upload_id: string | null;
  privacy: "public" | "unlisted" | "password";
  password_hash: string | null;
  chapters: string;
  cta: string | null;
  links: string;
  captions: string | null;
  has_thumbnail: number;
  has_preview: number;
  created_at: string;
};

export type Settings = {
  /** Shown on the viewer page instead of any Reel branding. */
  companyName: string;
  /** Player accent, as a hex color. */
  playerColor: string;
  hasLogo: boolean;
  logoVersion: number;
  /** Privacy given to new videos. */
  defaultPrivacy: "public" | "unlisted" | "password";
};

const DEFAULTS: Settings = {
  companyName: "",
  playerColor: "#E2703A",
  hasLogo: false,
  logoVersion: 0,
  defaultPrivacy: "unlisted",
};

export async function getSettings(env: Env): Promise<Settings> {
  const row = await env.DB.prepare("SELECT value FROM settings WHERE key = 'workspace'").first<{ value: string }>();
  return { ...DEFAULTS, ...(row ? (JSON.parse(row.value) as Partial<Settings>) : {}) };
}

export async function putSettings(env: Env, changes: Partial<Settings>): Promise<Settings> {
  const next = { ...(await getSettings(env)), ...changes };
  if (!/^#[0-9a-fA-F]{6}$/.test(next.playerColor)) next.playerColor = DEFAULTS.playerColor;
  next.companyName = String(next.companyName).slice(0, 80);
  await env.DB.prepare("INSERT INTO settings (key, value) VALUES ('workspace', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
    .bind(JSON.stringify(next))
    .run();
  return next;
}
