@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

#if os(macOS) || os(Linux)

@Test func mcpStdioTransportSendsLineDelimitedJSONRPCRequests() async throws {
    let script = #"""
while IFS= read -r line; do
  printf '%s\n' '{"jsonrpc":"2.0","id":7,"result":{"ok":true}}'
done
"""#
    let transport = MCPStdioTransport(command: "/bin/sh", args: ["-c", script])

    try await transport.start()
    let response = try await transport.request([
        "jsonrpc": "2.0",
        "id": 7,
        "method": "echo",
        "params": ["message": "hello"]
    ])
    try await transport.close()

    #expect(response["id"]?.intValue == 7)
    #expect(response["result"]?["ok"]?.boolValue == true)
}

@Test func mcpClientConnectsThroughStdioTransport() async throws {
    let script = #"""
while IFS= read -r line; do
  case "$line" in
    *server/discover*)
      printf '%s\n' '{"jsonrpc":"2.0","id":0,"error":{"code":-32601,"message":"Method not found"}}'
      ;;
    *notifications*initialized*)
      ;;
    *initialize*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"stdio-server","version":"1.0.0"}}}'
      ;;
    *tools*list*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"lookup","description":"Lookup via stdio","inputSchema":{"type":"object","properties":{"query":{"type":"string"}}}}]}}'
      ;;
    *tools*call*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"stdio result"}],"isError":false}}'
      ;;
  esac
done
"""#
    let transport = MCPStdioTransport(command: "/bin/sh", args: ["-c", script])
    let client = try await MCPClient.connect(transport: transport)

    #expect(await client.serverInfo == MCPImplementation(name: "stdio-server", version: "1.0.0"))

    let tools = try await client.tools()
    let lookup = try #require(tools["lookup"])
    #expect(lookup.description == "Lookup via stdio")

    let result = try await lookup.execute(["query": "swift"])
    #expect(result["content"]?[0]?["text"]?.stringValue == "stdio result")

    try await client.close()
}

@Test func mcpStdioTransportAnswersIncomingServerRequests() async throws {
    let script = #"""
IFS= read -r init
printf '%s\n' '{"jsonrpc":"2.0","id":99,"method":"ping"}'
IFS= read -r pong
case "$pong" in
  *99*)
    printf '%s\n' '{"jsonrpc":"2.0","id":0,"error":{"code":-32601,"message":"Method not found"}}'
    ;;
esac
while IFS= read -r line; do
  case "$line" in
    *notifications*initialized*)
      ;;
    *initialize*)
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"stdio-ping-server","version":"1.0.0"}}}'
      ;;
    *tools*list*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}'
      ;;
  esac
done
"""#
    let transport = MCPStdioTransport(command: "/bin/sh", args: ["-c", script])
    let client = try await MCPClient.connect(transport: transport)

    #expect(await client.serverInfo.name == "stdio-ping-server")
    #expect((try await client.listTools()).tools.isEmpty)

    try await client.close()
}

#endif
