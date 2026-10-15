import Foundation
import Combine
import SwiftUI

enum MagpieProviderState: Equatable, Sendable {
    case managedOnline(version: String)
    case managedOffline
    case directOnline(version: String)
    case installedNotRunning
    case notInstalled

    static func derive(
        connection: MagpieResolvedConnection,
        gateway: MagpieProviderStatusModel.Gateway,
        installation: MagpieProviderStatusModel.Installation
    ) -> MagpieProviderState {
        switch connection.mode {
        case .managed:
            switch gateway {
            case .online(let version):
                return .managedOnline(version: version)
            case .offline, .unknown:
                return .managedOffline
            }
        case .direct:
            switch gateway {
            case .online(let version):
                return .directOnline(version: version)
            case .offline, .unknown:
                if installation == .installed {
                    return .installedNotRunning
                } else {
                    return .notInstalled
                }
            }
        }
    }
}

@MainActor
final class MagpieProviderStatusModel: ObservableObject {

    enum Gateway: Equatable, Sendable {
        case unknown
        case online(version: String)
        case offline
    }

    enum Installation: Equatable, Sendable {
        case installed
        case notInstalled
    }

    @Published private(set) var connection: MagpieResolvedConnection
    @Published private(set) var gateway: Gateway = .unknown
    @Published private(set) var installation: Installation
    @Published private(set) var catalog: [MagpieModelCatalog.Entry] = []
    @Published var externalModelChangedNotice: String?

    private var pollTask: Task<Void, Never>?

    init() {
        let agentFile = MagpieAgentFile.load()
        let directBase = MagpieGateway.directBaseURL()
        let identity = MagpieGateway.directIdentity()
        let storedDirect = KeychainService.loadLLMCredentials(for: .magpie)?["directModel"]
        let resolved = MagpieConnectionResolver.resolve(
            agentFile: agentFile,
            storedDirectModel: (storedDirect?.isEmpty == false) ? storedDirect : nil,
            directBaseURL: directBase,
            directIdentity: identity
        )

        self.connection = resolved
        self.installation = MagpieInstallation.isInstalled() ? .installed : .notInstalled
    }

    var state: MagpieProviderState {
        MagpieProviderState.derive(
            connection: connection,
            gateway: gateway,
            installation: installation
        )
    }

    func start() {
        stop()
        refreshNow()

        pollTask = Task { [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { break }

                self.checkConnection()

                tickCount += 1
                if tickCount % 5 == 0 {
                    await self.checkGateway()
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() {
        installation = MagpieInstallation.isInstalled() ? .installed : .notInstalled
        checkConnection()
        Task { [weak self] in
            await self?.checkGateway(forceCatalogRefresh: true)
        }
    }

    private func checkConnection() {
        let agentFile = MagpieAgentFile.load()
        let directBase = MagpieGateway.directBaseURL()
        let identity = MagpieGateway.directIdentity()
        let storedDirect = KeychainService.loadLLMCredentials(for: .magpie)?["directModel"]
        let newResolved = MagpieConnectionResolver.resolve(
            agentFile: agentFile,
            storedDirectModel: (storedDirect?.isEmpty == false) ? storedDirect : nil,
            directBaseURL: directBase,
            directIdentity: identity
        )

        if newResolved != connection {
            let previousConnection = connection
            connection = newResolved

            if previousConnection.mode == .managed && newResolved.mode == .managed {
                if previousConnection.model != newResolved.model && !newResolved.model.isEmpty {
                    externalModelChangedNotice = newResolved.model
                }
            }
        }
    }

    private func checkGateway(forceCatalogRefresh: Bool = false) async {
        let prevGateway = gateway
        let hello = await MagpieGateway.hello(baseURL: connection.baseURL)

        switch hello {
        case .magpie(let version):
            gateway = .online(version: version)
            let wasOffline = prevGateway != .online(version: version)
            if wasOffline || forceCatalogRefresh || catalog.isEmpty {
                if let entries = try? await MagpieModelCatalog.shared.models(baseURL: connection.baseURL, forceRefresh: forceCatalogRefresh) {
                    self.catalog = entries
                }
            }
        case .notMagpie, .unreachable:
            gateway = .offline
        }
    }
}
