# AgencyZero ↔ AgentOne — XPC IPC spike

A macOS-only Rust spike answering one question: **is `rama-net-apple-xpc` 0.3.0
production-viable for a private mach-service XPC channel with peer code-signature
attestation, between a trusted parent (`agencyzero`) and an untrusted sidecar
(`agentone`)?**

**Answer: yes.** All three validations pass on the crate; the FFI fallback was not
needed. See [Recommendation](#recommendation).

This is a throwaway spike repo, deliberately separate from the real `agencyzero`
project. The binaries here are named `agencyzero`/`agentone` only to mirror the roles
they stand in for.

- [PLAN.md](PLAN.md) — the architecture plan this spike was built from.
- `./scripts/validate.sh` — reproduces every result below and leaves no system state
  behind.

**Host under test:** macOS 26.5 (25F71), Apple Silicon, Rust 1.97.0, Xcode 26 CLT.
**Target:** macOS 13+.

---

## Layout

```
agencyzero-xpc-spike-test/
├── Cargo.toml                    # workspace, resolver 3, edition 2024
├── crates/agencyzero/src/main.rs # listener: binds mach service, attests peer, echoes
├── crates/agentone/src/main.rs   # client: connects, sends hello, prints reply
├── scripts/
│   ├── make-identities.sh        # two throwaway self-signed codesign identities
│   ├── sign.sh                   # sign a binary, print its designated requirement
│   └── validate.sh               # full A + C driver, writes evidence to results/
└── results/                      # generated: logs, plists, signed variants (gitignored)
```

Run it:

```bash
./scripts/validate.sh
```

`agencyzero [--service NAME] [--require REQUIREMENT] [--spawn PATH]` and
`agentone [--service NAME] [--timeout SECS] [--require REQUIREMENT]`. Both `--require`
flags take a `codesign -r` requirement string; on `agencyzero` it attests the connecting
peer, on `agentone` it attests the server.

---

## Validation A — private mach service without a launchd plist

**Result: a plist is unavoidable. A listener cannot claim a mach service name that
launchd has not registered for it.** The minimal working plist is below.

### A1 — no registration at all

`XpcListener::bind` returns `Ok` and logs "listener activated" — then libxpc
asynchronously invalidates the listener:

```
[agencyzero] listening on mach service 'com.24x.agencyzero.spike' pid=88412
ERROR rama_net_apple_xpc::listener: xpc listener terminated by error event
      service=com.24x.agencyzero.spike
      error=xpc connection invalidated: Connection init failed at listener activation
            with error 1 - Operation not permitted
[agencyzero] listener terminated: Some(Invalidated(Some("Connection init failed at
             listener activation with error 1 - Operation not permitted")))
```

The client fails to find the name in the bootstrap namespace:

```
[agentone] request failed: Connection(Invalidated(Some("Connection init failed at
           lookup with error 3 - No such process")))
```

Note the trap: **`bind()` succeeding proves nothing.** The failure arrives on the event
stream milliseconds later. Any supervisor built on this must treat
`XpcListener::termination_reason()` / `accept()` returning `None` as the real bind
result, not the `Result` from `bind`.

### A2 — with the minimal LaunchAgent plist

Works, first try, full round trip:

```
[agencyzero] listening on mach service 'com.24x.agencyzero.spike' pid=88888
[agencyzero] peer connected: pid=88887 euid=501
[agencyzero] message from pid=88887: Dictionary({"hello": String("from-agentone"), "pid": Int64(88887)})
[agentone]   reply received: Dictionary({"echoed": Bool(true), "hello": String("from-agentone"),
                                         "pid": Int64(88887), "server_pid": Int64(88888)})
```

This is the **minimal** plist — every key below is load-bearing except the two log paths:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.24x.agencyzero.spike</string>
	<key>ProgramArguments</key>
	<array>
		<string>/abs/path/to/agencyzero</string>
		<string>--require</string>
		<string>identifier agentone and certificate leaf = H"&lt;sha1&gt;"</string>
	</array>
	<key>MachServices</key>
	<dict><key>com.24x.agencyzero.spike</key><true/></dict>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$UID /path/to/com.24x.agencyzero.spike.plist   # load
launchctl bootout   gui/$UID/com.24x.agencyzero.spike                  # unload
```

No `RunAtLoad` and no `KeepAlive` are needed: `MachServices` makes the job launch on
demand when the first client connects. A per-user `gui/$UID` LaunchAgent is enough —
no root, no `SMAppService`, no system daemon.

### A3 — can a manually launched process take the name over?

No. With launchd holding the name, a hand-started `agencyzero` gets the **same**
`Operation not permitted` invalidation as A1. Only the launchd-spawned instance may
check in.

**Consequence for the real design:** AgencyZero cannot be an arbitrary process that
happens to listen. It must be the launchd-registered job, started on demand by the
first connection (or by `launchctl kickstart`), and it spawns AgentOne itself — the
parent→child trust direction is unchanged, but the parent's *own* lifecycle belongs to
launchd. If that is unacceptable, the alternative is `XpcEndpoint::anonymous_channel()`
(no launchd at all), but an endpoint must be delivered over an already-established XPC
channel or an inherited fd, so it cannot bootstrap the first channel by itself.

---

## Validation B — public API, not a private symbol

**PASS — carried over from the reviewer's audit of the crates.io source, not re-derived
here.** `PeerSecurityRequirement::CodeSigning` calls the public
`xpc_connection_set_peer_code_signing_requirement` (`src/peer.rs:87`), with bindings
bindgen-generated from `<xpc/xpc.h>`. No private audit-token symbols.

One correction from this host's SDK: the symbol is available from **macOS 12.0**, not
13.0 —

```c
__API_AVAILABLE(macos(12.0), macCatalyst(15.0))
API_UNAVAILABLE(ios, tvos, watchos)
int
xpc_connection_set_peer_code_signing_requirement(xpc_connection_t connection, const char *requirement);
```

So the macOS 13+ target has a full release of headroom on this API.

---

## Validation C — code-signature attestation

**PASS. The correctly signed peer is served; a validly-signed-but-wrong-identity peer
and an ad-hoc-signed peer are both rejected by libxpc before a single byte reaches
application code.**

Setup: two throwaway self-signed code-signing identities (`SpikeGood`, `SpikeWrong`) in
a scratch keychain. Three copies of the *same* `agentone` binary, all signed with the
*same* signing identifier `agentone`, differing **only** in signing identity:

| variant | designated requirement |
|---|---|
| `agentone-good` | `identifier agentone and certificate leaf = H"cb34…78e2"` (SpikeGood) |
| `agentone-wrong` | `identifier agentone and certificate leaf = H"5058…408d"` (SpikeWrong) |
| `agentone-adhoc` | `cdhash H"7f3f…4909"` (ad-hoc, no identity) |

The listener enforces `identifier agentone and certificate leaf = H"<SpikeGood sha1>"`.

### Results

```
=== C — peer: agentone-wrong ===
[agentone] request failed: Connection(Interrupted) — xpc connection interrupted

=== C — peer: agentone-adhoc ===
[agentone] request failed: Connection(Interrupted) — xpc connection interrupted

=== C — peer: agentone-good ===
[agentone] reply received: Dictionary({"echoed": Bool(true), "hello": String("from-agentone"),
                                       "pid": Int64(90283), "server_pid": Int64(90280)})
[agentone] OK
```

The listener's own view — only the good peer exists at all; the two rejected peers
produce **no event whatsoever**, and the listener keeps serving afterwards:

```
[agencyzero] enforcing code-signing requirement: identifier agentone and certificate leaf = H"cb34…78e2"
[agencyzero] listening on mach service 'com.24x.agencyzero.spike' pid=90280
[agencyzero] peer connected: pid=90283 euid=501
[agencyzero] message from pid=90283: Dictionary({"hello": String("from-agentone"), "pid": Int64(90283)})
```

### The exact rejection

From the unified log, inside the listener process, emitted by libxpc:

```
Df agencyzero[90280] (libxpc.dylib) Code-signing requirement
   (identifier agentone and certificate leaf = H"cb34b62d697cd88b36df7f21e66a16b9ce2a78e2")
   set on connection
Df agencyzero[90280] [com.apple.xpc:connection] [0x10160d100]
   Dropping check-in message due to code signing requirement: <private>
```

Two `Dropping check-in message` lines, one per rejected peer. The rejection happens at
**check-in**, before the connection is ever vended to the server — which is why nothing
reaches Rust.

### Control — the rejection is attributable to the requirement

The same `agentone-wrong` binary against a listener with **no** requirement connects
and is served normally:

```
=== C — control: same wrong-signed peer against a listener with NO requirement ===
[agentone] reply received: Dictionary({..., "server_pid": Int64(90305)})
[agentone] OK
```

So the accept/reject split is caused by the requirement and nothing else.

### Correction to the brief: where `PeerRequirementFailed` actually surfaces

The brief said to assert on `XpcConnectionError::PeerRequirementFailed` on the
listener's event stream. **That variant never appears on the listener side** — as shown
above, libxpc silently drops the check-in and the server learns nothing. It *is*
observable in the opposite direction, when the **client** attests the **server**:

```
=== C — client-side requirement failure ===
[agentone] request failed: Connection(PeerRequirementFailed(Some("Peer Forbidden")))
           — xpc peer did not satisfy security requirement: Peer Forbidden
```

This asymmetry is Apple's design, not a crate defect, but it has a real operational
consequence: **a server cannot log, count, or alert on rejected peers from inside its
own process.** Attack visibility has to come from the unified log
(`Dropping check-in message due to code signing requirement`), not from application
code. Budget for that in the real AgencyZero.

A self-signed, untrusted leaf certificate is sufficient — `certificate leaf = H"…"` is
a hash comparison, so no trust-chain evaluation is involved. In production this becomes
`anchor apple generic and certificate leaf[subject.OU] = <TEAMID>` against a real
Developer ID.

---

## The crate without rama, and its dependency footprint

**Usable standalone: yes.** Neither binary imports a rama crate directly or names a
rama type; the whole spike is `use rama_net_apple_xpc::{…}` plus tokio. The crate does
expose `XpcServer` / `XpcConnector` as `rama_core::Service` implementations, but those
are opt-in — the listener/connection API stands on its own, and rama types
(`ArcStr`, `Extensions`) only appear where you can pass a `&str` and forget about it.

**Footprint: 111 unique transitive crates, 6 of them `rama-*`** (`rama-net-apple-xpc`,
`rama-core`, `rama-net`, `rama-utils`, `rama-error`, `rama-macros`). Full list in
`results/deps.txt`. That is a heavy tail for an IPC channel — it arrives via `rama-net`
and `rama-core` (tokio-graceful, futures, radix_trie, wildcard, ipnet, tracing +
tracing-appender, …), most of which nothing in the XPC path uses. Plus `bindgen` at
build time, which is what makes the first build ~26s and requires libclang.

## API friction

1. **`bind()` returns `Ok` for a name it does not own** (A1). The real failure is
   asynchronous. Every consumer must watch `termination_reason()`; this is the single
   sharpest edge in the crate.
2. **Peer rejection is invisible to the listener** — no event, no counter, no hook.
   Apple's behavior, but the crate could surface it by exposing the libxpc log signal
   or at least documenting the asymmetry, since its own docs for
   `PeerRequirementFailed` imply the listener sees it.
3. **The rustdoc under-promises on `bind`** ("no clients will be able to connect by
   name") when what actually happens is that the listener dies outright.
4. **Builder naming is macro-generated and non-obvious**: `with_peer_requirement(x)`,
   `maybe_with_peer_requirement(Option<x>)`, `without_peer_requirement()` all exist but
   none appear in the rendered signature list — you must know
   `rama_utils::macros::generate_set_and_with` to predict the API surface.
5. **`send_request` has no built-in timeout**; wrap it in `tokio::time::timeout` or a
   dead peer hangs the caller forever.
6. **Bounded event channel drops events at capacity with only a `warn!`** (10k default).
   Silent message loss under backpressure is a poor default for a security boundary.
7. **`edition = "2024"` / Rust 1.96+** rules out older toolchains, and bindgen requires
   Xcode CLT + libclang on every build host and CI runner.
8. Cosmetic: `tracing` output goes wherever the host configures it; the crate logs at
   `INFO` on every connection, which is noisy for a high-churn channel.

None of these is a correctness defect in the attestation path — which is the part that
had to be right.

---

## Recommendation

**Build the real AgencyZero↔AgentOne channel on `rama-net-apple-xpc`, not on owned
FFI.** The crate passes the only validation that actually mattered: it drives
`xpc_connection_set_peer_code_signing_requirement` through the public API, and the
kernel enforces it exactly as advertised — a wrong-signed peer and an ad-hoc-signed
peer are both dropped at check-in while the correctly signed peer is served, with a
clean control run proving the split is caused by the requirement alone. Getting there
took roughly 200 lines of ordinary Rust with no `unsafe`, whereas owned FFI would mean
hand-maintaining `block2` handler blocks, `xpc_object_t` retain/release discipline, and
dictionary marshalling — real ongoing risk in exchange for shedding a dependency tail
that, while genuinely heavy at 111 crates, is compile-time weight rather than runtime
attack surface. The two things to carry forward as engineering tasks rather than
blockers: never trust `bind()`'s `Ok` (watch `termination_reason()` and treat listener
termination as fatal), and accept that rejected peers are invisible from inside the
listener, so peer-rejection alerting must be built on the unified-log signal. If the
dependency tail later becomes intolerable — a hard binary-size budget, or a
no-tokio constraint — the escape hatch is cheap: the crate's surface used here is
narrow enough (bind, accept, recv, reply, connect, send_request, one requirement
setter) that a hand-rolled FFI module could replace it behind the same internal API
without touching either binary's logic, which is exactly why the spike was structured
this way.
