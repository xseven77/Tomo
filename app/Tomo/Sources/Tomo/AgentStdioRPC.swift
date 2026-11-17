import Foundation
import Darwin

/// One private process per registered runtime. No shell expansion; caller supplies
/// a trusted executable, arguments and explicitly scoped environment.
final class AgentStdioRPC: Sendable {
    let channel: AgentRPCChannel
    private let io: AgentStdioIO
    private let reader: Task<Void, Never>

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL? = nil) throws {
        let io = try AgentStdioIO(executable: executable, arguments: arguments, environment: environment, directory: directory)
        let channel = AgentRPCChannel(writer: {
            do { try await io.write($0) }
            catch { io.stop(); throw error }
        })
        self.io = io
        self.channel = channel
        reader = Task {
            do {
                while let bytes = try await io.read(), !Task.isCancelled {
                    try await channel.receive(bytes)
                }
                await channel.close()
            } catch {
                await channel.close((error as? AgentRPCError) ?? .disconnected)
            }
            io.stop()
        }
    }

    func stop() async {
        await channel.close()
        reader.cancel()
        io.stop()
        await reader.value
    }

    deinit { reader.cancel(); io.stop() }
}

private final class AgentStdioIO: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private let lock = NSLock()
    private var stopped = false
    private var queuedWrites = 0
    private var queuedWriteBytes = 0
    private let writeQueue = DispatchQueue(label: "tomo.agent-rpc.write")
    private let readQueue = DispatchQueue(label: "tomo.agent-rpc.read")

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL?) throws {
        process = Process()
        inputPipe = Pipe(); outputPipe = Pipe()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // Vendor stderr may contain private paths/content. Do not route it to API
        // consumers or the user's terminal; later diagnostics must be redacted.
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Release parent copies of child ends; otherwise EOF never arrives when
        // the process exits and the reader would remain blocked forever.
        try inputPipe.fileHandleForReading.close()
        try outputPipe.fileHandleForWriting.close()
        let descriptor = input.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(output.fileDescriptor, F_SETFL, fcntl(output.fileDescriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            process.terminate(); throw AgentRPCError.disconnected
        }
    }

    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard !stopped, queuedWrites < 128, queuedWriteBytes + bytes.count <= 32 * 1024 * 1024 else {
                lock.unlock(); reply.resume(throwing: AgentRPCError.overloaded); return
            }
            queuedWrites += 1
            queuedWriteBytes += bytes.count
            lock.unlock()
            writeQueue.async {
                defer {
                    self.lock.lock(); self.queuedWrites -= 1; self.queuedWriteBytes -= bytes.count; self.lock.unlock()
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                let success = bytes.withUnsafeBytes { raw -> Bool in
                    var offset = 0
                    while offset < raw.count {
                        guard ContinuousClock.now < deadline else { return false }
                        self.lock.lock()
                        guard !self.stopped else { self.lock.unlock(); return false }
                        // Nonblocking write under the lock avoids descriptor reuse
                        // races, while stop can interrupt a child that stops reading.
                        let count = Darwin.write(self.input.fileDescriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        let failure = errno
                        self.lock.unlock()
                        if count > 0 { offset += count }
                        else if failure == EAGAIN || failure == EINTR {
                            Thread.sleep(forTimeInterval: 0.01)
                        } else { return false }
                    }
                    return true
                }
                if success { reply.resume() } else { reply.resume(throwing: AgentRPCError.disconnected) }
            }
        }
    }

    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Data?, Error>) in
            readQueue.async {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    self.lock.lock()
                    guard !self.stopped else { self.lock.unlock(); reply.resume(returning: nil); return }
                    let count = Darwin.read(self.output.fileDescriptor, &bytes, bytes.count)
                    let failure = errno
                    self.lock.unlock()
                    if count > 0 { reply.resume(returning: Data(bytes.prefix(count))); return }
                    if count == 0 { reply.resume(returning: nil); return }
                    if failure == EAGAIN || failure == EINTR { Thread.sleep(forTimeInterval: 0.01) }
                    else { reply.resume(throwing: AgentRPCError.disconnected); return }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        try? input.close()
        try? output.close()
        let running = process.isRunning
        lock.unlock()
        if running {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if self.process.isRunning { _ = Darwin.kill(self.process.processIdentifier, SIGKILL) }
            }
        }
    }
}
