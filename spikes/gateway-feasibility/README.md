# Gateway Feasibility Spike

This spike verifies the desktop integration boundary without changing the production app:

- launch a bundled-style executable with `Process`;
- receive a ready handshake containing a random loopback port;
- keep `/health` public while protecting the control plane with a local bearer token;
- fetch a model alias list;
- consume semantic events over `text/event-stream`;
- request graceful shutdown and observe a zero exit status.

The primary mock service is a dependency-free Rust executable. The Swift verifier launches it exactly as the macOS app would launch a bundled helper. `mock_gateway.swift` remains as a transport-equivalent fallback and comparison fixture.

This validates the Rust build, process and transport contract. It does not validate real model-protocol translation.

Build and run:

```sh
mkdir -p /private/tmp/tomo-gateway-feasibility
cargo build
swiftc -parse-as-library -swift-version 5 verifier.swift -o /private/tmp/tomo-gateway-feasibility/verifier
/private/tmp/tomo-gateway-feasibility/verifier target/debug/tomo-gateway-feasibility
```
