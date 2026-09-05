# Orchestration limits

Caps enforced by `InMemoryAgentDirectory` / `DBAgentDirectory` for hierarchical multi-agent chat (`agents_spawn`, worker turns, mailboxes).

Settings → **Multi-agent** edits persisted limits. **New chat sessions** pick up saved values; existing tabs keep the limits they started with.

## Defaults (product)

| Field | Default | Meaning |
| --- | --- | --- |
| `maxDepth` | **2** | User-facing agent = depth 0. Allows main → worker → sub-worker. |
| `maxChildrenPerAgent` | **4** | Max direct children per parent (one parallel spawn wave). |
| `maxConcurrentTurns` | **4** | Max concurrent LLM turns across all agents in a session. |
| `maxAgentsPerSession` | **8** | Max registered agents including the user-facing agent. |
| `maxMailboxDepth` | **64** | Max queued envelopes per agent mailbox. |

## Settings ceilings

| Field | Min | Max |
| --- | --- | --- |
| `maxDepth` | 0 | 4 |
| `maxChildrenPerAgent` | 1 | 8 |
| `maxConcurrentTurns` | 1 | 8 |
| `maxAgentsPerSession` | 2 | 16 |
| `maxMailboxDepth` | 8 | 128 |

## Tuning notes

- **Depth 2** matches the common pattern: orchestrator spawns workers; a worker may spawn one specialist sub-agent. Depth 0 blocks all workers; depth 1 allows only direct workers.
- **4 children per parent** aligns with batch `agents_spawn` of a small worker set without unbounded fan-out.
- **4 concurrent turns** keeps LLM parallelism reasonable on one Mac. It is **independent** of the Docker container pool (max 3, 1 warm). Many parallel workers running `script_exec` may queue on containers even when turn concurrency allows 4.
- **8 agents per session** = 1 user-facing + up to 7 workers/specialists — enough for typical research/delegate flows without runaway registry growth.
- **Mailbox 64** is a safety valve for message bursts; rarely hit in normal chat.

## Code

- Policy struct: `Structure/Sources/AppLayerServices/AppServices/OrchestrationLimits.swift`
- Runtime snapshot: `OrchestrationLimitsRuntime.current`
- Enforcement: `packages/AgentRuntime/Sources/AgentRuntime/InMemoryAgentDirectory.swift`

## Revisit when

- Users routinely hit limits in production logs (`depthLimitReached`, `childLimitReached`, `sessionAgentLimitReached`).
- Container pool size increases and we want higher default `maxConcurrentTurns`.
- Jobs spawn multi-agent trees (today primarily chat sessions).
