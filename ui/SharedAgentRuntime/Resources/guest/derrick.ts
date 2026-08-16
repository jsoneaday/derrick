/**
 * Guest SDK. Import from "derrick".
 * `handle` must return HandleResult (JSON array of Envelope).
 * The host builds `event` and calls `handle`. Do not construct HandleEvent yourself.
 */
export type PluginVerb =
  | "http.request"
  | "result.emit"
  | "message.post"
  | "ui.present"
  | "secret.request"
  | "job.schedule"
  | "log";

export interface Envelope {
  verb: PluginVerb;
  type?: string;
  schema_version?: number;
  request_id?: string;
  method?: string;
  url?: string;
  title?: string;
  summary?: string;
  text?: string;
  content?: string;
  message?: string;
  auth_ref?: string | null;
  json?: unknown;
  headers?: Record<string, string>;
}

export type HandleResult = Envelope[];

export interface HttpResult {
  request_id?: string;
  status?: number;
  headers?: Record<string, string>;
  body?: string;
  error?: string | null;
}

/**
 * Type of one field on YOUR `interface PluginParams`.
 * `event.params` is an object of named fields, not a single PluginParamValue.
 */
export type PluginParamValue = string | number | boolean | readonly string[] | readonly number[];

/**
 * Constrains HandleEvent's type argument. Do not use this as your params type.
 * In the plugin, declare `interface PluginParams { topic?: string; max?: number }`
 * (empty `{}` if none) and write `handle(event: HandleEvent<PluginParams>)`.
 * Named fields only — no Record, no index signature, no unknown, no nested objects.
 */
export type ParamFields<P> = { [K in keyof P]?: PluginParamValue };

/**
 * Host-built invoke payload. `P` is your PluginParams object, not a value union.
 * Default is no fields. `params` may be omitted; handle must still work.
 */
export interface HandleEvent<P extends ParamFields<P> = Record<string, never>> {
  /** Host. `"http_results"` on the hop after you return netFetch(...). */
  kind?: string;
  /** Host. Prefer httpBody(event) / httpFailed(event). */
  http_results?: HttpResult[];
  /** Host. Matches your PluginParams. May be missing. */
  params?: P;
}

export function httpBody<P extends ParamFields<P>>(event: HandleEvent<P>): string {
  const row = Array.isArray(event.http_results) ? event.http_results[0] : undefined;
  return typeof row?.body === "string" ? row.body : "";
}

export function httpFailed<P extends ParamFields<P>>(event: HandleEvent<P>): boolean {
  const row = Array.isArray(event.http_results) ? event.http_results[0] : undefined;
  if (!row) return false;
  if (typeof row.error === "string" && row.error.length > 0) return true;
  if (typeof row.status === "number" && (row.status < 200 || row.status >= 400)) return true;
  return false;
}

/** Unwrap CDATA, then drop tags. Do not use /<[^>]*>/ on RSS — it deletes CDATA titles. */
export function stripMarkup(value: string): string {
  return String(value ?? "")
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/gi, "$1")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/&#x27;/gi, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/\s+/g, " ")
    .trim();
}

function collectTitles(src: string, patterns: RegExp[], max: number, minLen: number): string[] {
  const seen = new Set<string>();
  const all: string[] = [];
  for (const pattern of patterns) {
    for (const match of src.matchAll(pattern)) {
      const title = stripMarkup(match[1] ?? "");
      if (title.length < minLen || title.length > 200 || seen.has(title)) continue;
      seen.add(title);
      all.push(title);
      if (all.length >= max) return all;
    }
    if (all.length > 0) return all;
  }
  return all;
}

/** Headlines from a news HTML page. Also accepts RSS/Atom if that is what was fetched. */
export function headlines(body: string, max = 8): string[] {
  const src = String(body ?? "");
  const fromFeed = collectTitles(
    src,
    [
      /<item\b[\s\S]*?<title[^>]*>([\s\S]*?)<\/title>/gi,
      /<entry\b[\s\S]*?<title[^>]*>([\s\S]*?)<\/title>/gi,
    ],
    max,
    8
  );
  if (fromFeed.length > 0) return fromFeed;
  return collectTitles(src, [/<h[1-3][^>]*>([\s\S]*?)<\/h[1-3]>/gi], max, 12);
}

export type Handle<P extends ParamFields<P> = Record<string, never>> = (
  event: HandleEvent<P>
) => HandleResult | Promise<HandleResult>;

export interface NetFetchOptions {
  method?: string;
  url: string;
  authRef?: string | null;
  json?: unknown;
  headers?: Record<string, string>;
}

function oneRequest(opts: NetFetchOptions): Envelope {
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  return {
    verb: "http.request",
    request_id: id,
    method: (opts.method || "GET").toUpperCase(),
    url: opts.url || "",
    auth_ref: opts.authRef ?? null,
    json: opts.json ?? null,
    headers: opts.headers ?? {},
  };
}

export function netFetch(
  opts: NetFetchOptions | NetFetchOptions[] | { requests: NetFetchOptions[] }
): HandleResult {
  if (Array.isArray(opts)) {
    return opts.map(oneRequest);
  }
  if ("requests" in opts && Array.isArray(opts.requests)) {
    return opts.requests.map(oneRequest);
  }
  return [oneRequest(opts as NetFetchOptions)];
}
