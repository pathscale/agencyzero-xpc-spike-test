# AgencyZero ↔ AgentOne XPC Spike — Architecture & Execution Plan

**Author:** Claude (acting architect) · **Date:** 2026-07-25 · **Host:** macOS 26.5, Rust 1.97 (Homebrew), full Xcode at `/Applications/Xcode.app`

---

## 1. Objective

Decide whether **`rama-net-apple-xpc` 0.3.0** is production-viable as the IPC channel
between two processes we own:

- **AgencyZero** — trusted parent, XPC *listener* on a private mach service.
- **AgentOne** — untrusted sidecar the parent spawns, XPC *connector*.

The channel must be a **private mach service** with **peer code-signature
attestation** enforced by the kernel/libxpc, targeting **macOS 13+**.

The deliverable is a working cargo workspace, a README with validation results, and a
go/no-go recommendation: build on this crate, or on thin owned FFI
(`extern "C"` + `block2`).

## 2. What is already settled (do not re-verify)

Validation **B** was completed by a reviewer against the crates.io source of 0.3.0:

- `PeerSecurityRequirement::CodeSigning` calls the **public**
  `xpc_connection_set_peer_code_signing_requirement` (`src/peer.rs:87`). Bindings are
  bindgen-generated from `<xpc/xpc.h>`; no private audit-token symbols. **B = PASS.**
- A rejected peer surfaces as `XpcConnectionError::PeerRequirementFailed` on the event
  stream — validation C asserts on that.
- Listener uses `xpc_connection_create_mach_service` with
  `XPC_CONNECTION_MACH_SERVICE_LISTENER`; client uses flags `0` (per-user bootstrap
  namespace, not PRIVILEGED).
- Crate requires edition 2024 / Rust 1.96+ (host has 1.97 ✓) and Xcode CLT + libclang
  for bindgen (host has full Xcode ✓).

Remaining work: **validations A and C**, dependency-footprint audit, README,
recommendation, commit + push. While signing, also confirm the SDK min-OS annotation
on `xpc_connection_set_peer_code_signing_requirement` (expected `macos(13.0)`).

## 3. What I verified in the crate source (informs the design)

I pulled `rama-net-apple-xpc-0.3.0` from crates.io and read it. The API we will code
against:

| Concern | API |
|---|---|
| Listener | `XpcListener::bind(XpcListenerConfig::new(name).with_peer_requirement(Some(req)))` → `accept().await -> XpcConnection` |
| Client | `XpcConnection::connect(XpcClientConfig::new(name))` (flags 0 unless `.privileged(true)`) |
| Attestation | `PeerSecurityRequirement::CodeSigning(ArcStr)` — a `codesign -r`-syntax requirement string, applied to the connection **before activation** |
| Request/reply | client `send_request(XpcMessage) -> XpcMessage`; server `recv() -> XpcEvent::Message(ReceivedXpcMessage)` then `.reply(dict)` |
| Errors | `XpcEvent::Error(XpcConnectionError)`; rejection variant `PeerRequirementFailed` |

Two source-level findings that shape validation A:

1. The listener rustdoc states: *“The service name … must be registered with launchd
   via a plist file before `bind` is called. Without launchd registration, `bind` will
   succeed but no clients will be able to connect by name.”* So the crate authors
   expect a plist. We will still test plist-less operation empirically — libxpc
   behavior for per-user bootstrap names has shifted across macOS releases, and the
   claim deserves a measurement, not trust.
2. The crate offers `XpcEndpoint::anonymous_channel()` (no launchd at all), but an
   `XpcEndpoint` is itself an XPC object — it can only be handed to a peer over an
   existing XPC channel, so it cannot bootstrap the *first* parent↔child channel by
   itself. It is noted as an option for production topologies, not used in this spike.

Dependencies pulled in (from the crate manifest): `rama-core`, `rama-net`,
`rama-utils` (all `default-features = false`, `std` only), plus `tokio` (rt, sync),
`serde`, `ahash`, `parking_lot`, `block2`, and build-dep `bindgen`. The exact
transitive count will be measured with `cargo tree` after the first build.

## 4. Targets to build

Cargo workspace at `~/code/agencyzero-xpc-spike-test` (existing git repo, origin
`pathscale/agencyzero-xpc-spike-test`) with two binaries and no shared library crate —
the protocol is two string constants; a third crate would be ceremony. The spike lives
in its own repo, separate from the real `agencyzero` project.

### 4.1 `agencyzero` (bin) — trusted parent / listener

- Binds `XpcListener` on service name `com.24x.agencyzero.spike`
  (overridable via `--service <name>`).
- `--require <requirement-string>`: applies
  `PeerSecurityRequirement::CodeSigning(<string>)` to the listener config. Omitting
  it runs an open listener — needed so validation A (plumbing) is measured
  independently of validation C (attestation).
- Accept loop: for each accepted `XpcConnection`, logs peer `pid`/`euid`, then drains
  `recv()`. Every `XpcEvent::Message` is echoed back via `.reply()` with the original
  dictionary plus `"echoed": true` and `"server_pid"`. Every `XpcEvent::Error` is
  printed verbatim — this is where `PeerRequirementFailed` must appear in validation C.
- Prints `termination_reason()` if the listener itself dies (the signal that
  plist-less bind actually failed, even though `bind()` returned `Ok`).
- `--spawn <path-to-agentone>`: optionally spawns AgentOne itself after binding, to
  prove the production process model (parent spawns sidecar) in one command.

### 4.2 `agentone` (bin) — untrusted sidecar / connector

- `XpcConnection::connect` to the same service name (`--service` overridable).
- Sends `{"hello": "from-agentone", "pid": <pid>}` via `send_request` with a 5s
  timeout, prints the reply dictionary, exits 0.
- On failure prints the exact `XpcError` / `XpcEvent::Error` payload and exits
  non-zero — validation C's rejection evidence comes from this output plus the
  listener's log.

### 4.3 Scripts (all under `scripts/`, all idempotent)

- `make-identities.sh` — creates a throwaway keychain (`spike.keychain-db`) holding
  **two** self-signed code-signing identities: `SpikeGood` and `SpikeWrong`
  (openssl-generated cert with `extendedKeyUsage=codeSigning`, imported via
  `security import`, unlocked with `set-key-partition-list`). Two identities so the
  "wrong-signed" case in validation C is a *validly signed but different identity*
  binary — a stronger negative test than unsigned-only. Unsigned/ad-hoc is tested too.
- `sign.sh <identity> <binary>...` — codesigns with `--force --options runtime` off
  (plain signing; hardened runtime is out of scope for the spike) and prints the
  designated requirement via `codesign -d -r-`.
- `validate.sh` — end-to-end driver: builds, runs A (no plist → plist fallback if
  needed), creates identities, signs, runs C happy path, then C rejection paths
  (SpikeWrong-signed and unsigned), capturing exact outputs into `results/`.

### 4.4 `launchd/com.24x.agencyzero.spike.plist` — only if A requires it

Prepared minimal per-user LaunchAgent (the fallback the task asks to document):

```xml
Label            = com.24x.agencyzero.spike
ProgramArguments = [ <abs path>/agencyzero, --require, <req> ]
MachServices     = { com.24x.agencyzero.spike = true }
```

Loaded with `launchctl bootstrap gui/$UID <plist>`, removed with
`launchctl bootout gui/$UID/com.24x.agencyzero.spike`. Note the process-model
consequence if this is required: launchd owns the name, so in production AgencyZero
becomes the launchd-registered service (spawned on demand) and still spawns AgentOne
itself — parent/child trust direction is unchanged.

## 5. Directory structure

```
agencyzero-xpc-spike-test/
├── Cargo.toml                  # [workspace] members = crates/*, resolver 3
├── PLAN.md                     # this document
├── PLAN.pdf                    # PDF render of this document
├── README.md                   # validation results A/B/C + recommendation (final deliverable)
├── .gitignore                  # target/, results/, *.keychain-db
├── crates/
│   ├── agencyzero/
│   │   ├── Cargo.toml
│   │   └── src/main.rs         # listener/echo server (§4.1)
│   └── agentone/
│       ├── Cargo.toml
│       └── src/main.rs         # connector/hello client (§4.2)
├── scripts/
│   ├── make-identities.sh
│   ├── sign.sh
│   └── validate.sh
└── launchd/
    └── com.24x.agencyzero.spike.plist   # documented fallback for A
```

## 6. Validation protocols

### A — private mach service without launchd?

1. **Plist-less:** run signed-or-unsigned `agencyzero` (no `--require`), then
   `agentone`. Success = echo reply received. Watch the *listener* for a delayed
   `termination_reason` — per the crate docs, `bind()` lies (returns `Ok`) when the
   name isn't registered; the truth arrives asynchronously or as a client-side
   `ConnectionInvalid`.
2. If plist-less fails: bootstrap the §4.4 plist, rerun, record the **minimal** plist
   that works and the exact launchctl commands. Also test whether a *manually started*
   agencyzero can hold the name vs. only the launchd-spawned instance (check-in
   semantics decide the production process model).

**Report:** which mode works, exact failure output of the other, minimal plist.

### C — code-signature attestation

1. `make-identities.sh` → `SpikeGood`, `SpikeWrong`.
2. Sign both binaries with `SpikeGood`. Derive the requirement string from the leaf:
   `certificate leaf = H"<sha1-of-SpikeGood-cert>"` (self-signed ⇒ anchor clauses
   are useless; leaf-hash pinning is the honest spike equivalent of a real
   `anchor apple generic and certificate leaf[subject.OU] = <team>` requirement).
3. **Happy path:** listener with `--require`, SpikeGood-signed agentone → expect echo.
4. **Rejection path(s):** same listener; run (a) SpikeWrong-signed and (b) unsigned
   agentone → expect **no message delivered**, `PeerRequirementFailed` on the
   listener's event stream, and a connection-invalid error in the client. Capture
   both verbatim.
5. While in the SDK: quote the availability annotation on
   `xpc_connection_set_peer_code_signing_requirement` from
   `MacOSX.sdk/usr/include/xpc/connection.h`.

Known risk: requirement evaluation of a **self-signed, untrusted** leaf. If libxpc
refuses to evaluate untrusted chains, fallback within C is ad-hoc signing with a
`cdhash H"..."` requirement — equally kernel-enforced, still exercises the same API.
Whichever variant produces a clean accept/reject pair becomes the documented result.

### Dependency audit

`cargo tree` on the workspace: count total transitive crates, count `rama-*` crates,
note anything heavy (e.g. whether rama-net drags in TLS/HTTP machinery despite
`default-features = false`). This answers "usable without adopting rama?" concretely:
we use rama types (`Service`, `ArcStr`) only where the crate's signatures force them.

### Fallback: owned FFI

Only if C **fails through the crate** (bug in requirement plumbing, event-stream
loss, unbuildable): implement `agencyzero`/`agentone` directly on
`extern "C"` declarations of `xpc_connection_create_mach_service`,
`xpc_connection_set_event_handler` (+`block2` `RcBlock`),
`xpc_connection_set_peer_code_signing_requirement`, `xpc_dictionary_*`, rerun A + C.
The workspace layout is unchanged; the two binaries just swap their internals — this
is deliberate, so the spike measures the *crate*, not the architecture.

## 7. Exit criteria & deliverables

1. Workspace builds on stable Rust 1.97 with the crates.io crate (no git deps).
2. Validation A result recorded (plist-less verdict + minimal plist if needed).
3. Validation C: happy path echoes; wrong-signed and unsigned are rejected with
   captured `PeerRequirementFailed` evidence.
4. README.md with A/B/C results, dependency counts, friction list, and a
   one-paragraph crate-vs-FFI recommendation.
5. Commit and push to `origin` (github.com/pathscale/agencyzero-xpc-spike-test) once
   C passes.

## 8. Risks / open questions going in

- **Plist-less listening likely fails** (crate docs say so) — plan already includes
  the minimal-plist fallback; the spike's value is documenting the *exact* behavior.
- **Self-signed cert vs. requirement evaluation** — mitigated by the cdhash variant.
- **macOS 26 host vs. macOS 13 target** — API is available since 13.0; behavior
  differences on 13.x cannot be measured on this host and will be flagged as a
  residual risk in the README.
- **Crate maturity signals to watch:** event-channel backpressure (events dropped
  with a warn log at capacity), `bind()` succeeding on unregistered names, and the
  tracing/rama-core coupling — each goes in the friction list if observed.
