# ADR: Docker-only Swift script runtime

**Status:** Accepted  
**Date:** 2026-08-22

## Decision

`script_exec`, plugin factory builds, and approved plugin runs use one host-owned
Swift Docker boundary. The pinned image is
`swiftlang/swift:nightly-6.4.x-noble`.

Generated source is a standalone Swift program. It reads one JSON event from
standard input and writes a JSON array of Derrick envelopes to standard
output. The host dispatches HTTP, UI, secret, storage, and result operations.
The guest has no network, shell, process, or credential access.

The shared executor:

- pulls the pinned image when needed;
- creates read-only containers with `--network none`;
- provides an executable writable `/tmp` for compiler cache and artifacts;
- bounds concurrent work with the shared Swift container pool;
- compiles source with `swiftc` before running the compiled artifact;
- drains process output through the Docker helper so large artifacts cannot
  deadlock.

Scripts cannot declare package dependencies. The verifier rejects direct
network and process APIs, and the reviewer checks intent and secret literals.

## Envelope hops

The first invocation receives the caller's event. A Swift program can emit
`http.request`; the host validates and performs each request, then invokes the
same compiled artifact with an `http_results` event. A terminal
`result.emit` or `message.post` ends the run. Hop count and execution time are
bounded by `PluginContract` and `ContainerLifecycleRuntime`.

## Presentation

The raw terminal envelope remains available to callers. Plain text, Markdown,
CSV, and sanitized HTML are supported by the UI. HTML is passed through the
allowlist sanitizer before native rendering.

## Data migration

Migration 0026 removes persisted source and metadata from the retired script
runtime while retaining current standalone Swift records. The purge is
idempotent and intentionally has no rollback.
