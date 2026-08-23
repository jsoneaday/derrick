# File extractor skill

Use the `files.extract` MCP tool for attached PDFs, Office documents, HTML, CSV,
and Excel files. Do not generate an extractor script with `script_exec`.

Call `files.extract` directly from this chat. Do not submit it through
`jobs_create`.

The host copies this chat's attached files into a private job folder and mounts
that folder into Docker as `/data/in` (read-only) and `/data/out` (read-write).
The container cannot see the rest of the Mac.

Arguments:

- `operation`: `extract` (text/markdown) or `convert` (csv↔xlsx, or
  extract-style markdown/txt). Default `extract`.
- `output_format`: `markdown`, `txt`, `csv`, or `xlsx`. Default `markdown`.
- `filenames`: original attached file names. Omit to process every attached
  file in this chat.
- `timeout_seconds`: 1...180. Default 120.

Use the returned `preview` text to answer the user. Converted files are copied
to `export_directory` on this Mac. Tell the user those export names. Never ask
the user to run Docker or copy files by hand.
