# Third-party notices

Derrick uses the following open-source dependencies (via Swift Package Manager). See each project for license terms.

| Package | Repository | Version (pinned) |
|---------|------------|------------------|
| EventSource | https://github.com/mattt/eventsource | 1.4.1 |
| PartialJSON | https://github.com/itruf/PartialJSON | 0.0.2 |
| swift-atomics | https://github.com/apple/swift-atomics | 1.3.1 |
| swift-collections | https://github.com/apple/swift-collections | 1.6.0 |
| swift-log | https://github.com/apple/swift-log | 1.14.0 |
| swift-nio | https://github.com/apple/swift-nio | 2.101.2 |
| swift-sdk (MCP) | https://github.com/modelcontextprotocol/swift-sdk | 0.12.1 |
| swift-system | https://github.com/apple/swift-system | 1.7.2 |

## External services (bring your own credentials)

Derrick integrates with user-configured APIs. You supply your own keys and are subject to each provider's terms:

- **OpenAI** — https://openai.com/policies
- **Google Gemini** — https://ai.google.dev/terms
- **Slack** — https://slack.com/terms-of-service

## Runtime

- **Docker Desktop** — script and plugin execution use the `swiftlang/swift` container image (see `docs/adr-swift-script-runtime.md`).

## Project license

Derrick source code is licensed under the [Apache License 2.0](LICENSE).
