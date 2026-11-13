<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-mcp 1.2.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-mcp.git", from: "1.2.0")
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
## Behavior notes

OAuth discovery rejects HTTPS-to-HTTP redirects before another request. OAuth requests always include a resource: the canonical server URL with its fragment removed is the fallback when custom validation returns nil. A stored refresh token needs its original authorization-server binding; an unbound token must be cleared before dynamic client registration can save a new binding.

MCP Apps CSP metadata includes `baseUriDomains`; known domain arrays discard
non-string values while unknown fields remain available. Streamable HTTP
protocol discovery propagates the original network failure instead of issuing
legacy initialization against the same unreachable endpoint.

OAuth discovery uses the native DNS-pinned GET path for metadata-derived
origins. Untrusted token/registration endpoints require an explicitly supplied
transport that performs connect-time DNS validation. Configured server origins
retain their trust; new `trustedOrigin:` overloads let direct credential calls
identify an explicitly configured origin. This value must come from application
configuration, never response metadata. The original selectors remain available.
