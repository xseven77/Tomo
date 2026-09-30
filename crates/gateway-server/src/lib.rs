mod responses_bridge;
mod codex_stream;
pub mod model_health;
pub mod server;
pub use model_health::ModelHealthEngine;
pub use server::GatewayServer;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::thread;

    fn spawn_test_server() -> (u16, String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let token = "test-token-xyz".to_string();

        let token_clone = token.clone();
        let handle = thread::spawn(move || {
            let server = GatewayServer::new(token_clone);
            server.run_loop(listener).unwrap();
        });

        (port, token, handle)
    }

    fn send_request(port: u16, raw_http: &str) -> String {
        let mut stream = TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
        stream.write_all(raw_http.as_bytes()).unwrap();
        stream.flush().unwrap();

        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        response
    }

    #[test]
    fn test_server_health_and_unauthorized_status() {
        let (port, token, handle) = spawn_test_server();

        // 1. Health check is public
        let health_resp = send_request(port, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(health_resp.contains("200 OK"));
        assert!(health_resp.contains("\"status\":\"ok\""));

        // 2. Status without token gets 401
        let unauth_resp = send_request(port, "GET /status HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(unauth_resp.contains("401 Unauthorized"));

        // 3. Status with valid token gets 200 OK
        let auth_req = format!("GET /status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        let auth_resp = send_request(port, &auth_req);
        assert!(auth_resp.contains("200 OK"));
        assert!(auth_resp.contains("\"running\":true"));

        // Shutdown
        let shutdown_req = format!("POST /shutdown HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        let shutdown_resp = send_request(port, &shutdown_req);
        assert!(shutdown_resp.contains("200 OK"));

        handle.join().unwrap();
    }

    #[test]
    fn test_server_chat_rejects_legacy_fallback_alias() {
        let (port, token, handle) = spawn_test_server();

        let body = serde_json::json!({
            "model": "coding-smart",
            "messages": [{"role": "user", "content": "Hello"}],
            "stream": true
        }).to_string();

        let req = format!(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );

        let resp = send_request(port, &req);
        assert!(resp.contains("200 OK"));
        assert!(resp.contains("text/event-stream"));
        assert!(resp.contains("data: [DONE]"));
        assert!(resp.contains("无法识别该模型"));

        // Shutdown
        let shutdown_req = format!("POST /shutdown HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        send_request(port, &shutdown_req);
        handle.join().unwrap();
    }

    #[test]
    fn test_server_responses_rejects_legacy_fallback_alias() {
        let (port, token, handle) = spawn_test_server();

        let body = serde_json::json!({
            "model": "coding-fast",
            "instructions": "Refactor codebase",
            "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Fix warnings"}]}],
            "stream": true
        }).to_string();

        let req = format!(
            "POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );

        let resp = send_request(port, &req);
        assert!(resp.contains("502 Bad Gateway"));
        assert!(!resp.contains("event: response.completed"));

        // Shutdown
        let shutdown_req = format!("POST /shutdown HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        send_request(port, &shutdown_req);
        handle.join().unwrap();
    }

    #[test]
    fn test_server_anthropic_rejects_legacy_fallback_alias() {
        let (port, token, handle) = spawn_test_server();

        let body = serde_json::json!({
            "model": "coding-smart",
            "messages": [{"role": "user", "content": "Explain Rust async"}],
            "max_tokens": 1024,
            "stream": true
        }).to_string();

        let req = format!(
            "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );

        let resp = send_request(port, &req);
        assert!(resp.contains("502 Bad Gateway"));
        assert!(!resp.contains("event: message_stop"));

        // Shutdown
        let shutdown_req = format!("POST /shutdown HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        send_request(port, &shutdown_req);
        handle.join().unwrap();
    }

    #[test]
    fn test_server_model_health_endpoints() {
        let (port, token, handle) = spawn_test_server();

        // 1. GET /v1/models/all without auth -> 401
        let unauth = send_request(port, "GET /v1/models/all HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(unauth.contains("401 Unauthorized"));

        // 2. GET /v1/models/all with auth -> 200 OK
        let auth_req = format!("GET /v1/models/all HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        let resp = send_request(port, &auth_req);
        assert!(resp.contains("200 OK"));
        assert!(resp.contains("\"accounts\""));

        // 3. GET /internal/model-check/status without auth -> 401
        let unauth_status = send_request(port, "GET /internal/model-check/status HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(unauth_status.contains("401 Unauthorized"));

        // 4. GET /internal/model-check/status with auth -> 200 OK
        let auth_status_req = format!("GET /internal/model-check/status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        let status_resp = send_request(port, &auth_status_req);
        assert!(status_resp.contains("200 OK"));
        assert!(status_resp.contains("\"running\":false"));

        // 5. POST /internal/model-check without auth -> 401
        let unauth_post = send_request(port, "POST /internal/model-check HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(unauth_post.contains("401 Unauthorized"));

        // 6. POST /internal/model-check/cancel without auth -> 401
        let unauth_cancel = send_request(port, "POST /internal/model-check/cancel HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(unauth_cancel.contains("401 Unauthorized"));

        // 7. POST /internal/model-check/cancel with auth when no job running -> 200 OK (idempotent idle)
        let auth_cancel = format!("POST /internal/model-check/cancel HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        let cancel_resp = send_request(port, &auth_cancel);
        assert!(cancel_resp.contains("200 OK") && cancel_resp.contains("alreadyIdle"));

        // Shutdown
        let shutdown_req = format!("POST /shutdown HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        send_request(port, &shutdown_req);
        handle.join().unwrap();
    }

    #[test]
    fn test_server_token_rotation_and_grace_period() {
        let (port, token, handle) = spawn_test_server();

        // 1. Initial token works
        let req1 = format!("GET /status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        let resp1 = send_request(port, &req1);
        assert!(resp1.contains("200 OK"));

        // 2. Rotate token without auth -> 401
        let rotate_body = "{\"new_token\":\"new-secret-999\"}";
        let unauth_rotate = format!(
            "POST /internal/token/rotate HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n{}",
            rotate_body.len(),
            rotate_body
        );
        let unauth_resp = send_request(port, &unauth_rotate);
        assert!(unauth_resp.contains("401 Unauthorized"));

        // 3. Rotate token with current auth -> 200 OK
        let rotate_req = format!(
            "POST /internal/token/rotate HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\nContent-Length: {}\r\n\r\n{}",
            rotate_body.len(),
            rotate_body
        );
        let rotate_resp = send_request(port, &rotate_req);
        assert!(rotate_resp.contains("200 OK"));
        assert!(rotate_resp.contains("\"rotated\":true"));

        // 4. New token works immediately
        let req_new = "GET /status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer new-secret-999\r\n\r\n";
        let resp_new = send_request(port, req_new);
        assert!(resp_new.contains("200 OK"));

        // 5. Old token works during grace period
        let req_old = format!("GET /status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\n\r\n");
        let resp_old = send_request(port, &req_old);
        assert!(resp_old.contains("200 OK"));

        // 6. Unknown token is rejected
        let req_bad = "GET /status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer completely-bogus\r\n\r\n";
        let resp_bad = send_request(port, req_bad);
        assert!(resp_bad.contains("401 Unauthorized"));

        // Shutdown using new token
        let shutdown_req = "POST /shutdown HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer new-secret-999\r\n\r\n";
        send_request(port, shutdown_req);
        handle.join().unwrap();
    }
}
