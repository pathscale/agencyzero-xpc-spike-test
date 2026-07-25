//! AgentOne — untrusted sidecar. Connects to AgencyZero's private mach service,
//! sends a hello dictionary via request/reply, and prints the reply.

use std::collections::BTreeMap;
use std::process::exit;
use std::time::Duration;

use rama_net_apple_xpc::{
    PeerSecurityRequirement, XpcClientConfig, XpcConnection, XpcEvent, XpcMessage,
};

const DEFAULT_SERVICE: &str = "com.24x.agencyzero.spike";

fn parse_args() -> (String, u64, Option<String>) {
    let mut service = DEFAULT_SERVICE.to_owned();
    let mut timeout_secs = 5u64;
    let mut require = None;
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = |name: &str| {
            it.next().unwrap_or_else(|| {
                eprintln!("missing value for {name}");
                exit(64);
            })
        };
        match flag.as_str() {
            "--service" => service = value("--service"),
            "--timeout" => {
                timeout_secs = value("--timeout").parse().unwrap_or_else(|_| {
                    eprintln!("--timeout must be an integer number of seconds");
                    exit(64);
                })
            }
            "--require" => require = Some(value("--require")),
            other => {
                eprintln!(
                    "unknown flag {other}; usage: agentone [--service NAME] [--timeout SECS] [--require REQUIREMENT]"
                );
                exit(64);
            }
        }
    }
    (service, timeout_secs, require)
}

/// After a failure, surface whatever lifecycle events the connection queued —
/// this is where XpcConnectionError variants (e.g. Invalidated) appear.
async fn drain_events(conn: &mut XpcConnection) {
    while let Ok(Some(event)) = tokio::time::timeout(Duration::from_millis(750), conn.recv()).await
    {
        match &event {
            XpcEvent::Error(err) => {
                eprintln!("[agentone] connection event: {err:?} — {err}");
                break;
            }
            other => eprintln!("[agentone] connection event: {other:?}"),
        }
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let (service, timeout_secs, require) = parse_args();
    println!("[agentone] pid={} connecting to '{service}'", std::process::id());

    // The client may attest the *server* too; this is the direction in which
    // XpcConnectionError::PeerRequirementFailed is observable from Rust.
    let mut config = XpcClientConfig::new(service.as_str());
    if let Some(requirement) = &require {
        println!("[agentone] requiring server to satisfy: {requirement}");
        config = config.with_peer_requirement(PeerSecurityRequirement::CodeSigning(
            requirement.as_str().into(),
        ));
    }

    let mut conn = match XpcConnection::connect(config) {
        Ok(conn) => conn,
        Err(err) => {
            eprintln!("[agentone] connect failed: {err:?} — {err}");
            exit(1);
        }
    };

    let hello = XpcMessage::Dictionary(BTreeMap::from([
        (
            "hello".to_owned(),
            XpcMessage::String("from-agentone".to_owned()),
        ),
        (
            "pid".to_owned(),
            XpcMessage::Int64(std::process::id() as i64),
        ),
    ]));

    match tokio::time::timeout(Duration::from_secs(timeout_secs), conn.send_request(hello)).await {
        Ok(Ok(reply)) => {
            println!("[agentone] reply received: {reply:?}");
            println!("[agentone] OK");
        }
        Ok(Err(err)) => {
            eprintln!("[agentone] request failed: {err:?} — {err}");
            drain_events(&mut conn).await;
            exit(1);
        }
        Err(_) => {
            eprintln!("[agentone] request timed out after {timeout_secs}s");
            drain_events(&mut conn).await;
            exit(1);
        }
    }
}
