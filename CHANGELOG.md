# Changelog

## 1.4.0

- Fail Streamable HTTP requests with an MCPClientError if the POST event stream ends or disconnects before the matching JSON-RPC response. Reviewed npm: @ai-sdk/mcp 2.0.99 to 2.0.102. Offline validation passed: node Scripts/test-packages.mjs (56 packages, 3672 owning tests and 1760 compatibility tests), generation, tooling, isolation, and version selection. See Docs/Archive/WeeklyUpstreamAudit20261122.md for retained gaps. Paid provider calls were skipped.
  Compatibility: Source-compatible Streamable HTTP error correction. Requires SwiftAI Core 1.3.0 for the existing MCP tool title and metadata contract.
