// Hard caps that keep the account inside the R2 free tier. Cloudflare has no spending limit of its own,
// so every R2 operation goes through here first and is refused before it could cost anything.

export class QuotaError extends Error {
  constructor(public readonly reason: "storage" | "writes" | "reads") {
    super(
      reason === "storage"
        ? "Storage limit reached: delete or archive videos to free space."
        : "Monthly sharing limit reached: links work again on the 1st of next month.",
    );
  }
}

export function currentMonth(now = new Date()): string {
  return now.toISOString().slice(0, 7);
}

export async function storageUsed(env: Env): Promise<number> {
  const row = await env.DB.prepare("SELECT COALESCE(SUM(size_bytes), 0) AS used FROM videos").first<{ used: number }>();
  return row?.used ?? 0;
}

/** Refuses an upload that would take total storage over the cap. */
export async function assertStorageFor(env: Env, extraBytes: number): Promise<void> {
  const used = await storageUsed(env);
  if (used + extraBytes > Number(env.STORAGE_CAP_BYTES)) throw new QuotaError("storage");
}

/**
 * Counts `count` R2 operations of the given class for this month, refusing them if the cap is reached.
 * The check and the increment are one statement, so concurrent requests cannot both slip past the cap.
 */
export async function spendOps(env: Env, kind: "write" | "read", count = 1): Promise<void> {
  const column = kind === "write" ? "write_ops" : "read_ops";
  const cap = Number(kind === "write" ? env.WRITE_OPS_CAP_MONTH : env.READ_OPS_CAP_MONTH);
  const month = currentMonth();
  await env.DB.prepare("INSERT OR IGNORE INTO usage (month) VALUES (?)").bind(month).run();
  const result = await env.DB.prepare(`UPDATE usage SET ${column} = ${column} + ? WHERE month = ? AND ${column} + ? <= ?`)
    .bind(count, month, count, cap)
    .run();
  if (result.meta.changes === 0) throw new QuotaError(kind === "write" ? "writes" : "reads");
}

export async function usageSummary(env: Env) {
  const month = currentMonth();
  const ops = await env.DB.prepare("SELECT write_ops, read_ops FROM usage WHERE month = ?")
    .bind(month)
    .first<{ write_ops: number; read_ops: number }>();
  return {
    month,
    storageBytes: await storageUsed(env),
    storageCapBytes: Number(env.STORAGE_CAP_BYTES),
    writeOps: ops?.write_ops ?? 0,
    writeOpsCap: Number(env.WRITE_OPS_CAP_MONTH),
    readOps: ops?.read_ops ?? 0,
    readOpsCap: Number(env.READ_OPS_CAP_MONTH),
  };
}
