import Foundation
import Network

/// TCP reachability through NWConnection, not ICMP ping; requires only com.apple.security.network.client,
/// already available in the MAS sandbox. Ported unchanged from SSH Keys Manager.
enum SSHConfigHostReachabilityStatus: Equatable {
    case checking, reachable, unreachable, error
}

struct SSHHostReachabilityTarget: Equatable {
    let host: String
    let port: UInt16
}

enum SSHHostReachabilityResolution: Equatable {
    case unsupported
    case invalidConfiguration(String)
    case target(SSHHostReachabilityTarget)
}

enum SSHHostReachabilityCheckResult: Equatable {
    case reachable, unreachable, error(String)
}

enum SSHHostReachabilityChecker {
    static func check(target: SSHHostReachabilityTarget, timeout: Duration) async -> SSHHostReachabilityCheckResult {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(target.host),
                                          port: NWEndpoint.Port(rawValue: target.port) ?? .ssh, using: .tcp)
            let queue = DispatchQueue(label: "SSHHostReachabilityChecker.\(target.host).\(target.port)")
            let state = ReachabilityContinuationState()
            let finish: @Sendable (SSHHostReachabilityCheckResult) -> Void = { result in
                connection.stateUpdateHandler = nil
                connection.cancel()
                state.resume(continuation: continuation, result: result)
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready: finish(.reachable)
                case .failed(let error): finish(classify(error))
                default: break
                }
            }
            Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                finish(.unreachable)
            }
            connection.start(queue: queue)
        }
    }

    private static func classify(_ error: NWError) -> SSHHostReachabilityCheckResult {
        switch error {
        case .dns: return .unreachable
        case .posix(let code):
            switch code {
            case .ETIMEDOUT, .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN, .ECONNRESET:
                return .unreachable
            default: return .error(error.localizedDescription)
            }
        default: return .error(error.localizedDescription)
        }
    }
}

enum SSHHostReachabilityResolver {
    static func resolveTarget(for entry: SSHConfigEntry) -> SSHHostReachabilityResolution {
        let tokens = entry.host.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 1, let alias = tokens.first, isSupportedAlias(alias) else { return .unsupported }
        let resolvedHost = entry.hostName
        guard !resolvedHost.isEmpty else { return .invalidConfiguration(String(localized: "HostName is empty for \(alias)")) }
        guard isSupportedResolvedHost(resolvedHost) else { return .unsupported }
        guard let port = resolvePort(for: entry) else { return .invalidConfiguration(String(localized: "Port is invalid for \(alias)")) }
        return .target(SSHHostReachabilityTarget(host: resolvedHost, port: port))
    }

    private static func isSupportedAlias(_ alias: String) -> Bool {
        !alias.contains("*") && !alias.contains("?") && !alias.contains("!")
    }
    private static func isSupportedResolvedHost(_ host: String) -> Bool {
        !host.contains("%") && host.split(whereSeparator: \.isWhitespace).count == 1
    }
    private static func resolvePort(for entry: SSHConfigEntry) -> UInt16? {
        guard let raw = entry.port else { return 22 }
        guard let port = UInt16(raw), port > 0 else { return nil }
        return port
    }
}

private final class ReachabilityContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    func resume(continuation: CheckedContinuation<SSHHostReachabilityCheckResult, Never>, result: SSHHostReachabilityCheckResult) {
        lock.lock(); defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: result)
    }
}
