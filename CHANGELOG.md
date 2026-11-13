# Changelog

## 1.2.0

- Preserve discovery network failures and sanitize MCP Apps CSP baseUriDomains. Metadata-derived OAuth endpoints use native protected download hooks or explicitly trusted/protected transports; configured-origin credential trust remains explicit. Existing exact OAuth selectors remain callable. Reviewed npm delta: @ai-sdk/mcp 2.0.93 to 2.0.99. Validation: `node Scripts/test-packages.mjs` passed all 52 owning suites and 1731 facade tests; tooling 27/27, generation/isolation checks, standalone exports and 106 minimum/latest consumers, documentation check and 101-page build passed. Publication requires green exact-source Swift 6.3.3 CI. Paid/live verification and full-package parity are not claimed.
  Compatibility: Additive native APIs or capabilities under the project minor-release convention. npm baselines and Swift SemVer are independent; this reviewed delta does not establish full-package or live-service parity.
