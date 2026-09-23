use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

const LOCAL_TOKEN: &str = "tomo-feasibility-token";

fn response(status: &str, content_type: &str, body: &str) -> Vec<u8> {
    format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}

fn handle(mut stream: TcpStream) -> std::io::Result<bool> {
    let mut buffer = [0_u8; 65_536];
    let count = stream.read(&mut buffer)?;
    let request = String::from_utf8_lossy(&buffer[..count]);
    let request_line = request.lines().next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let path = parts.next().unwrap_or_default();
    let authorized = request
        .lines()
        .any(|line| line.eq_ignore_ascii_case(&format!("Authorization: Bearer {LOCAL_TOKEN}")));

    let (payload, should_stop) = match (method, path, authorized) {
        ("GET", "/health", _) => (
            response(
                "200 OK",
                "application/json",
                r#"{"status":"ok","service":"tomo-rust-gateway-feasibility"}"#,
            ),
            false,
        ),
        ("GET", "/status", true) => (
            response(
                "200 OK",
                "application/json",
                r#"{"running":true,"bind":"127.0.0.1","active_requests":0}"#,
            ),
            false,
        ),
        ("GET", "/v1/models", true) => (
            response(
                "200 OK",
                "application/json",
                r#"{"object":"list","data":[{"id":"coding-smart","object":"model"}]}"#,
            ),
            false,
        ),
        ("GET", "/events", true) => {
            let events = concat!(
                "event: gateway.ready\ndata: {\"sequence\":1}\n\n",
                "event: request.started\ndata: {\"sequence\":2,\"request_id\":\"req_spike\"}\n\n",
                "event: request.completed\ndata: {\"sequence\":3,\"request_id\":\"req_spike\"}\n\n"
            );
            (response("200 OK", "text/event-stream", events), false)
        }
        ("POST", "/shutdown", true) => (
            response("200 OK", "application/json", r#"{"stopping":true}"#),
            true,
        ),
        (_, "/status" | "/v1/models" | "/events" | "/shutdown", false) => (
            response(
                "401 Unauthorized",
                "application/json",
                r#"{"error":"unauthorized"}"#,
            ),
            false,
        ),
        _ => (
            response(
                "404 Not Found",
                "application/json",
                r#"{"error":"not_found"}"#,
            ),
            false,
        ),
    };

    stream.write_all(&payload)?;
    stream.flush()?;
    Ok(should_stop)
}

fn main() -> std::io::Result<()> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    println!(
        r#"{{"event":"ready","host":"127.0.0.1","port":{},"token":"{}"}}"#,
        address.port(),
        LOCAL_TOKEN
    );
    std::io::stdout().flush()?;

    for incoming in listener.incoming() {
        match incoming {
            Ok(stream) => {
                if handle(stream)? {
                    break;
                }
            }
            Err(error) => eprintln!("connection failed: {error}"),
        }
    }
    Ok(())
}
