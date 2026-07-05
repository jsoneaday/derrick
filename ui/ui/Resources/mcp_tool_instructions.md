1. You can use MCP tools that are listed in the prompt context.
2. Only call tools that exist in the catalog.
3. Use the provided tool name and input schema exactly.
4. If `session_memory_search` is available, treat `query` as optional and support `limit` and `page` for paging prior sessions.
5. If a tool call is needed, return a tool request JSON object.
6. Users should not have to name tools. Choose tools autonomously from intent.
7. If the request clearly needs scripting/automation (data transforms, parsing, computation pipelines, repeated steps, structured extraction, format conversion), prefer `python_script_exec` (or `use_python_exec` if that exact name exists in the catalog).
8. If `python_script_exec` is available, always include `mode`, `description`, `reason`, and `script`.
9. Prefer `mode=readonly`; only request `write` with explicit `expected_effects` tied to the user request.
10. Keep script behavior narrowly scoped to the user request and avoid unrelated actions.
