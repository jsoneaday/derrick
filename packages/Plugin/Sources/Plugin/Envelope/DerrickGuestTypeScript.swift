import Foundation

/// TypeScript guest SDK generated from `PluginEnvelopeSchema.jsonSchema`.
public enum DerrickGuestTypeScript {
    public static var verbUnion: String {
        PluginEnvelopeSchema.verbCases.map { "\"\($0)\"" }.joined(separator: " | ")
    }

    public static var derrickModule: String {
        """
        /**
         * Generated from PluginEnvelopeSchema.jsonSchema. Do not edit by hand.
         * `handle` must return HandleResult (JSON array of Envelope).
         */
        export type PluginVerb = \(verbUnion);

        export interface Envelope {
          verb: PluginVerb;
          type?: string;
          request_id?: string;
          method?: string;
          url?: string;
          title?: string;
          summary?: string;
          text?: string;
          content?: string;
          message?: string;
          [key: string]: unknown;
        }

        export type HandleResult = Envelope[];

        export interface HttpResult {
          request_id?: string;
          status?: number;
          headers?: Record<string, string>;
          body?: string;
          error?: string | null;
        }

        export interface HandleEvent {
          kind?: string;
          http_results?: HttpResult[];
          [key: string]: unknown;
        }

        export function httpBody(event: HandleEvent): string {
          const row = Array.isArray(event.http_results) ? event.http_results[0] : undefined;
          return typeof row?.body === "string" ? row.body : "";
        }

        export type Handle = (event: HandleEvent) => HandleResult | Promise<HandleResult>;

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
        """
    }

    public static var tsconfigJSON: String {
        """
        {
          "compilerOptions": {
            "strict": true,
            "noEmit": true,
            "noImplicitAny": true,
            "target": "ES2022",
            "module": "ESNext",
            "moduleResolution": "bundler",
            "skipLibCheck": true,
            "moduleDetection": "force",
            "types": [],
            "paths": { "derrick": ["/opt/derrick/derrick.ts"] }
          },
          "files": ["script.ts", "handle-check.ts"]
        }
        """
    }

    public static var handleCheckTS: String {
        """
        import { handle } from "./script";
        import type { HandleEvent, HandleResult } from "derrick";
        export const __derrickHandleCheck: (event: HandleEvent) => HandleResult | Promise<HandleResult> = handle;
        """
    }
}

extension PluginEnvelopeSchema {
    /// Verb enums parsed from `jsonSchema` so generated TS cannot drift.
    public static var verbCases: [String] {
        guard let enumRange = jsonSchema.range(of: "\"enum\"") else { return [] }
        let after = jsonSchema[enumRange.upperBound...]
        guard let start = after.firstIndex(of: "["), let end = after.firstIndex(of: "]") else {
            return []
        }
        let body = after[after.index(after: start)..<end]
        return body.split(separator: ",").compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
            return String(trimmed.dropFirst().dropLast())
        }
    }

    public static var ragSection: String {
        """
        # handle() return (TypeScript + JSON)

        Guest is TypeScript on Bun. `export function handle(event: HandleEvent): HandleResult`.
        Stdout MUST be a JSON **array** of envelopes (never a string or bare object).
        Import helpers from `derrick` (`netFetch` already returns `HandleResult`).

        ## Generated types (from the same JSON Schema Swift decodes)

        ```typescript
        \(DerrickGuestTypeScript.derrickModule)
        ```

        ## JSON Schema

        ```json
        \(jsonSchema)
        ```
        """
    }
}
