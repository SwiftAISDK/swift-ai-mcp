# Changelog

## 1.1.1

- Correct canonical OAuth resource fallback, original refresh-token binding before DCR and discovery HTTPS downgrade rejection. Reviewed published upstream delta: @ai-sdk/mcp 2.0.88 to 2.0.93. Validation passed: node Scripts/test-packages.mjs (all 52 owning packages plus the complete local facade; 3,965 reported tests and 33 explicit live skips); node Scripts/sdk.mjs dev test; node Scripts/sdk.mjs generate --check; node --test Scripts/tests/*.test.cjs (27 passed); core/provider isolation and version resolution; 52 deterministic package exports, 106 catalog consumers and four additional exact retained-minimum graphs; docs-site install/check/build (100 pages); git diff --check. No paid live-service calls were run. The publication pipeline requires successful Swift 6.3.3 CI at the exact canonical source before publishing.
  Compatibility: Patch release for behavior/header corrections without new required owning API. Existing call sites and exact old selectors are retained. Direct minimums change only for concrete API use or required inherited behavior. Version-delta review does not establish full-package parity or live-service acceptance.
