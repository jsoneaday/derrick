# ADR: Docker-only Swift script runtime

**Status:** Superseded  
**Date:** 2026-08-22  
**Superseded:** 2026-09-06 — `script_exec` and `plugin.invoke` use the Python guest runtime (`python:3.14.7` / `derrick-guest-runtime`). Leftover `derrick-swift-runtime` containers are still swept on daemon Docker init.

## Decision (historical)

`script_exec`, plugin factory builds, and approved plugin runs previously used one host-owned
Swift Docker boundary. The pinned image was
`swiftlang/swift:nightly-6.4.x-noble`.

Generated source was a standalone Swift program. It read one JSON event from
standard input and wrote a JSON array of Derrick envelopes to standard
output. The host dispatched HTTP, UI, secret, storage, and result operations.
The guest had no network, shell, process, or credential access.

That guest language path is removed. The envelope hop contract is unchanged and
language-agnostic (JSON Schema). Current guest implementation is Python.

## Envelope hops

The first invocation receives the caller's event. A guest program can emit
`http.request`; the host validates and performs each request, then invokes the
same source with an `http_results` event. A terminal
`result.emit` or `message.post` ends the run. Hop count and execution time are
bounded by `PluginContract` and `ContainerLifecycleRuntime`.

## Presentation

The raw terminal envelope remains available to callers. Plain text, Markdown,
CSV, and sanitized HTML are supported by the UI. HTML is passed through the
allowlist sanitizer before native rendering.

## Data migration

Migration 0026 removes persisted source and metadata from the retired script
runtime while retaining current standalone records. The purge is
idempotent and intentionally has no rollback.
