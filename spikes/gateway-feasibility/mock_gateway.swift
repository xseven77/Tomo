import Foundation
import Network

private let queue = DispatchQueue(label: "tomo.gateway.feasibility")
private let localToken = "tomo-feasibility-token"

private func httpResponse(
    status: String,
    contentType: String = "application/json",
    body: String
) -> Data {
    let bodyData = Data(body.utf8)
    let head = [
        "HTTP/1.1 \(status)",
        "Content-Type: \(contentType)",
        "Content-Length: \(bodyData.count)",
        "Connection: close",
        "",
        "",
    ].joined(separator: "\r\n")
    return Data(head.utf8) + bodyData
}

private func handle(_ connection: NWConnection, listener: NWListener) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
        guard error == nil, let data, let request = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        let method = requestLine.first ?? ""
        let path = requestLine.count > 1 ? requestLine[1] : ""
        let authorized = lines.contains { $0.caseInsensitiveCompare("Authorization: Bearer \(localToken)") == .orderedSame }

        let response: Data
        var shouldStop = false

        switch (method, path) {
        case ("GET", "/health"):
            response = httpResponse(
                status: "200 OK",
                body: #"{"status":"ok","service":"tomo-gateway-feasibility"}"#
            )
        case ("GET", "/status") where authorized:
            response = httpResponse(
                status: "200 OK",
                body: #"{"running":true,"bind":"127.0.0.1","active_requests":0}"#
            )
        case ("GET", "/v1/models") where authorized:
            response = httpResponse(
                status: "200 OK",
                body: #"{"object":"list","data":[{"id":"coding-smart","object":"model"}]}"#
            )
        case ("GET", "/events") where authorized:
            let events = [
                "event: gateway.ready\ndata: {\"sequence\":1}\n\n",
                "event: request.started\ndata: {\"sequence\":2,\"request_id\":\"req_spike\"}\n\n",
                "event: request.completed\ndata: {\"sequence\":3,\"request_id\":\"req_spike\"}\n\n",
            ].joined()
            response = httpResponse(status: "200 OK", contentType: "text/event-stream", body: events)
        case ("POST", "/shutdown") where authorized:
            response = httpResponse(status: "200 OK", body: #"{"stopping":true}"#)
            shouldStop = true
        case (_, "/status"), (_, "/v1/models"), (_, "/events"), (_, "/shutdown"):
            response = httpResponse(status: "401 Unauthorized", body: #"{"error":"unauthorized"}"#)
        default:
            response = httpResponse(status: "404 Not Found", body: #"{"error":"not_found"}"#)
        }

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
            if shouldStop {
                listener.cancel()
                queue.asyncAfter(deadline: .now() + 0.05) { exit(0) }
            }
        })
    }
}

do {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                fputs("missing listener port\n", stderr)
                exit(2)
            }
            print(#"{"event":"ready","host":"127.0.0.1","port":\#(port),"token":"tomo-feasibility-token"}"#)
            fflush(stdout)
        case .failed(let error):
            fputs("listener failed: \(error)\n", stderr)
            exit(3)
        default:
            break
        }
    }
    listener.newConnectionHandler = { connection in
        handle(connection, listener: listener)
    }
    listener.start(queue: queue)
    dispatchMain()
} catch {
    fputs("unable to start listener: \(error)\n", stderr)
    exit(1)
}
