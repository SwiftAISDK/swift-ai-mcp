<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-mcp 1.0.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-mcp.git", from: "1.0.0")
```

Products: `SwiftAIMCP`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# SwiftAIMCP

Swift-native port of `@ai-sdk/mcp`. Maintained in the canonical SwiftAISDK repository and exported as an independent Swift package.

Import `SwiftAIMCP` for `MCPClient`, HTTP/stdio transports, OAuth helpers, MCP Apps
metadata and event delivery adapters. The existing client, transport and tool APIs
are preserved. MCP tool conversion uses `SwiftAI` from `swift-ai-core`; core does
not import MCP. Stdio remains limited to the supported host platforms.

Run `swift test --package-path Packages/swift-ai-mcp` in the canonical checkout.
Runtime and translated tests follow the versions and gaps in `Porting/map.json`
and the canonical version ledger. Distribution manifests are catalog-generated.
