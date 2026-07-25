//! AgencyZero — trusted parent. Binds an XpcListener on a private mach service,
//! optionally enforcing a code-signing peer requirement, and echoes every
//! dictionary it receives back to the sender.

use std::collections::BTreeMap;
use std::process::exit;

use rama_net_apple_xpc::{
    PeerSecurityRequirement, XpcConnection, XpcEvent, XpcListener, XpcListenerConfig, XpcMessage,
};

const DEFAULT_SERVICE: &str = "com.24x.agencyzero.spike";

struct Args {
    service: String,
    require: Option<String>,
    spawn: Option<String>,
}

fn parse_args() -> Args {
    let mut args = Args {
        service: DEFAULT_SERVICE.to_owned(),
        require: None,
        spawn: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = |name: &str| {
            it.next().unwrap_or_else(|| {
                eprintln!("missing value for {name}");
                exit(64);
            })
        };
        match flag.as_str() {
            "--service" => args.service = value("--service"),
            "--require" => args.require = Some(value("--require")),
            "--spawn" => args.spawn = Some(value("--spawn")),
            other => {
                eprintln!("unknown flag {other}; usage: agencyzero [--service NAME] [--require REQUIREMENT] [--spawn PATH]");
                exit(64);
            }
        }
    }
    args
}

async fn handle_peer(mut conn: XpcConnection) {
    let (pid, euid) = (conn.pid(), conn.euid());
    println!("[agencyzero] peer connected: pid={pid} euid={euid}");
    while let Some(event) = conn.recv().await {
        match event {
            XpcEvent::Message(received) => {
                println!("[agencyzero] message from pid={pid}: {:?}", received.message());
                let mut reply = match received.message().clone() {
                    XpcMessage::Dictionary(dict) => dict,
                    other => BTreeMap::from([("received".to_owned(), other)]),
                };
                reply.insert("echoed".to_owned(), XpcMessage::Bool(true));
                reply.insert(
                    "server_pid".to_owned(),
                    XpcMessage::Int64(std::process::id() as i64),
                );
                if let Err(err) = received.reply(XpcMessage::Dictionary(reply)) {
                    eprintln!("[agencyzero] reply to pid={pid} failed: {err}");
                }
            }
            XpcEvent::Connection(_) => {
                eprintln!("[agencyzero] unexpected nested connection from pid={pid}");
            }
            XpcEvent::Error(err) => {
                // This is where a rejected peer shows up when a
                // PeerSecurityRequirement is active: PeerRequirementFailed.
                println!("[agencyzero] connection error from pid={pid}: {err:?} — {err}");
            }
        }
    }
    println!("[agencyzero] peer pid={pid} event stream closed");
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

    let args = parse_args();

    let mut config = XpcListenerConfig::new(args.service.as_str());
    if let Some(requirement) = &args.require {
        println!("[agencyzero] enforcing code-signing requirement: {requirement}");
        config = config.with_peer_requirement(PeerSecurityRequirement::CodeSigning(
            requirement.as_str().into(),
        ));
    } else {
        println!("[agencyzero] WARNING: no peer requirement (open listener)");
    }

    let mut listener = match XpcListener::bind(config) {
        Ok(listener) => listener,
        Err(err) => {
            eprintln!("[agencyzero] bind failed: {err:?} — {err}");
            exit(1);
        }
    };
    println!("[agencyzero] listening on mach service '{}' pid={}", args.service, std::process::id());

    if let Some(path) = &args.spawn {
        match std::process::Command::new(path)
            .args(["--service", &args.service])
            .spawn()
        {
            Ok(child) => println!("[agencyzero] spawned sidecar {path} pid={}", child.id()),
            Err(err) => eprintln!("[agencyzero] failed to spawn {path}: {err}"),
        }
    }

    loop {
        match listener.accept().await {
            Some(conn) => {
                tokio::spawn(handle_peer(conn));
            }
            None => {
                eprintln!(
                    "[agencyzero] listener terminated: {:?}",
                    listener.termination_reason()
                );
                exit(2);
            }
        }
    }
}
