// =============================================================================
// Logger structuré — préfixe [mm/<name>] requestId=... pour grep facile.
// =============================================================================

export function newRequestId(): string {
  return crypto.randomUUID();
}

export function makeLogger(name: string, requestId: string) {
  const prefix = `[mm/${name}] requestId=${requestId}`;
  return {
    info: (msg: string, extra?: Record<string, unknown>) =>
      console.log(prefix, msg, extra ?? ""),
    warn: (msg: string, extra?: Record<string, unknown>) =>
      console.warn(prefix, msg, extra ?? ""),
    error: (msg: string, extra?: Record<string, unknown>) =>
      console.error(prefix, msg, extra ?? ""),
  };
}

export type Logger = ReturnType<typeof makeLogger>;
