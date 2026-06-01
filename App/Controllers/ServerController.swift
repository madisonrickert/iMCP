import AppKit
import MCP
import Network
import OSLog
import Ontology
import SwiftUI
import SystemPackage
import UserNotifications

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let serviceType = "_mcp._tcp"
private let serviceDomain = "local."

private let log = Logger.server

struct ServiceConfig: Identifiable {
    let id: String
    let name: String
    let iconName: String
    let color: Color
    let service: any Service
    let binding: Binding<Bool>

    var isActivated: Bool {
        get async {
            await service.isActivated
        }
    }

    init(
        name: String,
        iconName: String,
        color: Color,
        service: any Service,
        binding: Binding<Bool>
    ) {
        self.id = String(describing: type(of: service))
        self.name = name
        self.iconName = iconName
        self.color = color
        self.service = service
        self.binding = binding
    }
}

enum ServiceRegistry {
    static let services: [any Service] = {
        var services: [any Service] = [
            CalendarService.shared,
            CallHistoryService.shared,
            CaptureService.shared,
            ContactsService.shared,
            LocationService.shared,
            MapsService.shared,
            MessageService.shared,
            RemindersService.shared,
            ShortcutsService.shared,
            UtilitiesService.shared,
            ClipboardService.shared,
        ]
        #if WEATHERKIT_AVAILABLE
            services.append(WeatherService.shared)
        #endif
        return services
    }()

    static func configureServices(
        calendarEnabled: Binding<Bool>,
        callHistoryEnabled: Binding<Bool>,
        captureEnabled: Binding<Bool>,
        clipboardEnabled: Binding<Bool>,
        contactsEnabled: Binding<Bool>,
        locationEnabled: Binding<Bool>,
        mapsEnabled: Binding<Bool>,
        messagesEnabled: Binding<Bool>,
        remindersEnabled: Binding<Bool>,
        shortcutsEnabled: Binding<Bool>,
        utilitiesEnabled: Binding<Bool>,
        weatherEnabled: Binding<Bool>
    ) -> [ServiceConfig] {
        var configs: [ServiceConfig] = [
            ServiceConfig(
                name: "Calendar",
                iconName: "calendar",
                color: .red,
                service: CalendarService.shared,
                binding: calendarEnabled
            ),
            ServiceConfig(
                name: "Call History",
                iconName: "phone.fill",
                color: .green.mix(with: .blue, by: 0.3),
                service: CallHistoryService.shared,
                binding: callHistoryEnabled
            ),
            ServiceConfig(
                name: "Capture",
                iconName: "camera.on.rectangle.fill",
                color: .gray.mix(with: .black, by: 0.7),
                service: CaptureService.shared,
                binding: captureEnabled
            ),
            ServiceConfig(
                name: "Clipboard",
                iconName: "doc.on.clipboard.fill",
                color: .teal,
                service: ClipboardService.shared,
                binding: clipboardEnabled
            ),
            ServiceConfig(
                name: "Contacts",
                iconName: "person.crop.square.filled.and.at.rectangle.fill",
                color: .brown,
                service: ContactsService.shared,
                binding: contactsEnabled
            ),
            ServiceConfig(
                name: "Location",
                iconName: "location.fill",
                color: .blue,
                service: LocationService.shared,
                binding: locationEnabled
            ),
            ServiceConfig(
                name: "Maps",
                iconName: "mappin.and.ellipse",
                color: .purple,
                service: MapsService.shared,
                binding: mapsEnabled
            ),
            ServiceConfig(
                name: "Messages",
                iconName: "message.fill",
                color: .green,
                service: MessageService.shared,
                binding: messagesEnabled
            ),
            ServiceConfig(
                name: "Reminders",
                iconName: "list.bullet",
                color: .orange,
                service: RemindersService.shared,
                binding: remindersEnabled
            ),
            ServiceConfig(
                name: "Shortcuts",
                iconName: "square.2.layers.3d",
                color: .indigo,
                service: ShortcutsService.shared,
                binding: shortcutsEnabled
            ),
        ]
        #if WEATHERKIT_AVAILABLE
            configs.append(
                ServiceConfig(
                    name: "Weather",
                    iconName: "cloud.sun.fill",
                    color: .cyan,
                    service: WeatherService.shared,
                    binding: weatherEnabled
                )
            )
        #endif
        return configs
    }
}

@MainActor
final class ServerController: ObservableObject {
    @Published var serverStatus: String = "Starting..."
    @Published var pendingConnectionID: String?
    @Published var pendingClientName: String = ""

    private var activeApprovalDialogs: Set<String> = []
    private var pendingApprovals: [(String, () -> Void, () -> Void)] = []
    private var currentApprovalHandlers: (approve: () -> Void, deny: () -> Void)?
    private let approvalWindowController = ConnectionApprovalWindowController()

    private let networkManager = ServerNetworkManager()

    // MARK: - AppStorage for Service Enablement States
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("callHistoryEnabled") private var callHistoryEnabled = false
    @AppStorage("captureEnabled") private var captureEnabled = false
    @AppStorage("clipboardEnabled") private var clipboardEnabled = true
    @AppStorage("contactsEnabled") private var contactsEnabled = false
    @AppStorage("locationEnabled") private var locationEnabled = false
    @AppStorage("mapsEnabled") private var mapsEnabled = true  // Default enabled
    @AppStorage("messagesEnabled") private var messagesEnabled = false
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @AppStorage("shortcutsEnabled") private var shortcutsEnabled = false
    @AppStorage("utilitiesEnabled") private var utilitiesEnabled = true  // Default enabled
    @AppStorage("weatherEnabled") private var weatherEnabled = false

    // MARK: - AppStorage for Trusted Clients
    @AppStorage("trustedClients") private var trustedClientsData = Data()

    // MARK: - Computed Properties for Service Configurations and Bindings
    var computedServiceConfigs: [ServiceConfig] {
        ServiceRegistry.configureServices(
            calendarEnabled: $calendarEnabled,
            callHistoryEnabled: $callHistoryEnabled,
            captureEnabled: $captureEnabled,
            clipboardEnabled: $clipboardEnabled,
            contactsEnabled: $contactsEnabled,
            locationEnabled: $locationEnabled,
            mapsEnabled: $mapsEnabled,
            messagesEnabled: $messagesEnabled,
            remindersEnabled: $remindersEnabled,
            shortcutsEnabled: $shortcutsEnabled,
            utilitiesEnabled: $utilitiesEnabled,
            weatherEnabled: $weatherEnabled
        )
    }

    private var currentServiceBindings: [String: Binding<Bool>] {
        Dictionary(
            uniqueKeysWithValues: computedServiceConfigs.map {
                ($0.id, $0.binding)
            }
        )
    }

    // MARK: - Trusted Clients Management
    private var trustedClients: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: trustedClientsData)) ?? []
        }
        set {
            trustedClientsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private func isClientTrusted(_ clientName: String) -> Bool {
        trustedClients.contains(clientName)
    }

    private func addTrustedClient(_ clientName: String) {
        var clients = trustedClients
        clients.insert(clientName)
        trustedClients = clients
    }

    func removeTrustedClient(_ clientName: String) {
        var clients = trustedClients
        clients.remove(clientName)
        trustedClients = clients
    }

    func getTrustedClients() -> [String] {
        Array(trustedClients).sorted()
    }

    func resetTrustedClients() {
        trustedClients = Set<String>()
    }

    // MARK: - Connection Approval Methods
    private func cleanupApprovalState() {
        pendingClientName = ""
        currentApprovalHandlers = nil

        if let clientID = pendingConnectionID {
            activeApprovalDialogs.remove(clientID)
            pendingConnectionID = nil
        }
    }

    private func handlePendingApprovals(for clientID: String, approved: Bool) {
        while let pendingIndex = pendingApprovals.firstIndex(where: { $0.0 == clientID }) {
            let (_, pendingApprove, pendingDeny) = pendingApprovals.remove(at: pendingIndex)
            if approved {
                log.notice("Approving pending connection for client: \(clientID)")
                pendingApprove()
            } else {
                log.notice("Denying pending connection for client: \(clientID)")
                pendingDeny()
            }
        }
    }

    init() {
        Task {
            // Initialize bindings from AppStorage before the server starts.
            await networkManager.updateServiceBindings(self.currentServiceBindings)
            await self.networkManager.start()
            self.updateServerStatus("Running")

            await networkManager.setConnectionApprovalHandler {
                [weak self] connectionID, clientInfo in
                guard let self = self else {
                    return false
                }

                log.debug("ServerManager: Approval handler called for client \(clientInfo.name)")

                // Bridge approval UI actions back into the async handler.
                return await withCheckedContinuation { continuation in
                    let resumeGate = ResumeGate()
                    let resumeOnce: (Bool) async -> Void = { value in
                        guard await resumeGate.shouldResume() else { return }
                        continuation.resume(returning: value)
                    }

                    Task { @MainActor in
                        self.showConnectionApprovalAlert(
                            clientID: clientInfo.name,
                            approve: {
                                Task { await resumeOnce(true) }
                            },
                            deny: {
                                Task { await resumeOnce(false) }
                            }
                        )
                    }
                }
            }
        }
    }

    func updateServiceBindings(_ bindings: [String: Binding<Bool>]) async {
        // Called by the UI when service toggles change.
        await networkManager.updateServiceBindings(bindings)
    }

    func startServer() async {
        await networkManager.start()
        updateServerStatus("Running")
    }

    func stopServer() async {
        await networkManager.stop()
        updateServerStatus("Stopped")
    }

    func setEnabled(_ enabled: Bool) async {
        await networkManager.setEnabled(enabled)
        updateServerStatus(enabled ? "Running" : "Disabled")
    }

    private func updateServerStatus(_ status: String) {
        log.info("Server status updated: \(status)")
        self.serverStatus = status
    }

    private func sendClientConnectionNotification(clientName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Client Connected"
        content.body = "Client '\(clientName)' has connected to iMCP"
        content.threadIdentifier = "client-connection-\(clientName)"

        let request = UNNotificationRequest(
            identifier: "client-connection-\(clientName)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log.error("Failed to send notification: \(error.localizedDescription)")
            } else {
                log.info("Sent notification for client connection: \(clientName)")
            }
        }
    }

    private func showConnectionApprovalAlert(
        clientID: String,
        approve: @escaping () -> Void,
        deny: @escaping () -> Void
    ) {
        log.notice("Connection approval requested for client: \(clientID)")

        // Trusted clients auto-approve without showing the dialog.
        if isClientTrusted(clientID) {
            log.notice("Client \(clientID) is already trusted, auto-approving")
            approve()

            // Notify the user on auto-approved connections.
            sendClientConnectionNotification(clientName: clientID)

            return
        }

        self.pendingConnectionID = clientID

        // Coalesce concurrent approvals for the same client.
        guard !activeApprovalDialogs.contains(clientID) else {
            log.info("Adding to pending approvals for client: \(clientID)")
            pendingApprovals.append((clientID, approve, deny))
            return
        }

        activeApprovalDialogs.insert(clientID)

        // Present the approval window and wire callbacks.
        pendingClientName = clientID
        currentApprovalHandlers = (approve: approve, deny: deny)

        approvalWindowController.showApprovalWindow(
            clientName: clientID,
            onApprove: { alwaysTrust in
                if alwaysTrust {
                    self.addTrustedClient(clientID)

                    // Ask for notification permission to alert on future trusted connections.
                    UNUserNotificationCenter.current().requestAuthorization(options: [
                        .alert, .sound, .badge,
                    ]) { granted, error in
                        if let error = error {
                            log.error(
                                "Failed to request notification permissions: \(error.localizedDescription)"
                            )
                        } else {
                            log.info("Notification permissions granted: \(granted)")
                        }
                    }
                }

                approve()
                self.cleanupApprovalState()
                self.handlePendingApprovals(for: clientID, approved: true)
            },
            onDeny: {
                deny()
                self.cleanupApprovalState()
                self.handlePendingApprovals(for: clientID, approved: false)
            }
        )

        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Connection Management Components

// Manages a single MCP connection.
actor MCPConnectionManager {
    private let connectionID: UUID
    private let connection: NWConnection
    private let server: MCP.Server
    private var transport: NetworkTransport
    private let parentManager: ServerNetworkManager

    init(connectionID: UUID, connection: NWConnection, parentManager: ServerNetworkManager) {
        self.connectionID = connectionID
        self.connection = connection
        self.parentManager = parentManager

        self.transport = NetworkTransport(
            connection: connection,
            logger: nil,
            heartbeatConfig: .init(enabled: false),
            reconnectionConfig: .disabled,
            bufferConfig: .unlimited
        )

        // MCP server instance for this connection.
        self.server = MCP.Server(
            name: Bundle.main.name ?? "iMCP",
            version: Bundle.main.shortVersionString ?? "unknown",
            capabilities: MCP.Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )
    }

    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws {
        do {
            log.notice("Starting MCP server for connection: \(self.connectionID)")
            try await server.start(transport: transport) { [weak self] clientInfo, capabilities in
                guard let self = self else { throw MCPError.connectionClosed }

                log.info("Received initialize request from client: \(clientInfo.name)")

                // Request user approval for the connection.
                let approved = await approvalHandler(clientInfo)
                log.info(
                    "Approval result for connection \(connectionID): \(approved ? "Approved" : "Denied")"
                )

                if !approved {
                    await self.parentManager.removeConnection(self.connectionID)
                    throw MCPError.connectionClosed
                }
            }

            log.notice("MCP Server started successfully for connection: \(self.connectionID)")

            // Register handlers after successful approval.
            await registerHandlers()

            // Monitor connection health for early disconnects.
            await startHealthMonitoring()
        } catch {
            log.error("Failed to start MCP server: \(error.localizedDescription)")
            throw error
        }
    }

    private func registerHandlers() async {
        await parentManager.registerHandlers(for: server, connectionID: connectionID)
    }

    private func startHealthMonitoring() async {
        // Monitor until the manager stops or the connection fails.
        Task {
            outer: while await parentManager.isRunning() {
                switch connection.state {
                case .ready, .setup, .preparing, .waiting:
                    break
                case .cancelled:
                    log.error("Connection \(self.connectionID) was cancelled, removing")
                    await parentManager.removeConnection(connectionID)
                    break outer
                case .failed(let error):
                    log.error(
                        "Connection \(self.connectionID) failed with error \(error), removing"
                    )
                    await parentManager.removeConnection(connectionID)
                    break outer
                @unknown default:
                    log.debug("Connection \(self.connectionID) in unknown state, skipping")
                }

                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
            }
        }
    }

    func notifyToolListChanged() async {
        do {
            log.info("Notifying client that tool list changed")
            try await server.notify(ToolListChangedNotification.message())
        } catch {
            log.error("Failed to notify client of tool list change: \(error)")

            // Clean up if the underlying NWConnection is closed.
            if let nwError = error as? NWError,
                nwError.errorCode == 57 || nwError.errorCode == 54
            {
                log.debug("Connection appears to be closed")
                await parentManager.removeConnection(connectionID)
            }
        }
    }

    func stop() async {
        await server.stop()
        connection.cancel()
    }
}

// Manages Bonjour service discovery and advertisement.
actor NetworkDiscoveryManager {
    private let serviceType: String
    private let serviceDomain: String
    var listener: NWListener
    private let browser: NWBrowser
    private let pathMonitor = NWPathMonitor()

    // All Network.framework callbacks run on this dedicated queue rather than
    // `.main`. A stalled SwiftUI main thread must never be able to freeze
    // advertisement or recovery — that is the "process alive at 0% CPU but not
    // advertising" wedge this whole subsystem now guards against.
    private let queue = DispatchQueue(label: "co.dododo.iMCP.network")

    // Whether our own advertised service is currently visible via Bonjour.
    // The listener can self-report `.ready` while mDNSResponder has silently
    // dropped the record (e.g. after sleep/wake); a listener-state check alone
    // cannot see that, but the browser can.
    private var ownServiceVisible = false

    // The service advertises under the stock (device-derived) Bonjour instance
    // name, so we learn the concrete registered name from the listener's
    // service-registration updates and use it to recognize our own record in
    // browser results.
    private var advertisedServiceName: String?
    private var latestBrowseResults: Set<NWBrowser.Result> = []

    // Invoked when the network path becomes satisfied again (sleep/wake,
    // network change) — a common trigger for a dropped Bonjour registration.
    private var onPathSatisfied: (@Sendable () -> Void)?

    init(serviceType: String, serviceDomain: String) throws {
        self.serviceType = serviceType
        self.serviceDomain = serviceDomain

        self.listener = try Self.makeListener(
            serviceType: serviceType,
            serviceDomain: serviceDomain
        )

        // Browser confirms our own advertisement is actually discoverable.
        self.browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: serviceDomain),
            using: Self.makeParameters()
        )

        log.info("Network discovery manager initialized with Bonjour service type: \(serviceType)")
    }

    private static func makeParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false
        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            tcpOptions.version = .v4
        }
        return parameters
    }

    private static func makeListener(
        serviceType: String,
        serviceDomain: String
    ) throws -> NWListener {
        let listener = try NWListener(using: makeParameters())
        listener.service = NWListener.Service(type: serviceType, domain: serviceDomain)
        return listener
    }

    func setOnPathSatisfied(_ handler: @escaping @Sendable () -> Void) {
        self.onPathSatisfied = handler
    }

    func start(
        stateHandler: @escaping @Sendable (NWListener.State) -> Void,
        connectionHandler: @escaping @Sendable (NWConnection) -> Void
    ) {
        listener.stateUpdateHandler = stateHandler
        listener.newConnectionHandler = connectionHandler
        // Track the concrete instance name mDNSResponder registers for us, so
        // we can tell our own record apart in browser results.
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            Task { await self?.handleRegistrationChange(change) }
        }
        listener.start(queue: queue)

        // Consume browser results (previously created but never read) to track
        // whether our service is genuinely being advertised.
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.updateBrowseResults(results) }
        }
        browser.start(queue: queue)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.firePathSatisfied() }
        }
        pathMonitor.start(queue: queue)

        log.info("Started network discovery and advertisement on dedicated queue")
    }

    func currentListenerState() -> NWListener.State { listener.state }

    func isOwnServiceVisible() -> Bool { ownServiceVisible }

    private func handleRegistrationChange(_ change: NWListener.ServiceRegistrationChange) {
        switch change {
        case .add(let endpoint):
            if case .service(let name, _, _, _) = endpoint {
                advertisedServiceName = name
            }
        case .remove(let endpoint):
            if case .service(let name, _, _, _) = endpoint, name == advertisedServiceName {
                advertisedServiceName = nil
            }
        @unknown default:
            break
        }
        recomputeOwnServiceVisibility()
    }

    private func updateBrowseResults(_ results: Set<NWBrowser.Result>) {
        latestBrowseResults = results
        recomputeOwnServiceVisibility()
    }

    // The browser only browses our service type + domain, so matching the
    // registered instance name is enough to identify our own advertisement.
    private func recomputeOwnServiceVisibility() {
        guard let advertisedServiceName else {
            ownServiceVisible = false
            return
        }
        ownServiceVisible = latestBrowseResults.contains { result in
            if case .service(let name, _, _, _) = result.endpoint {
                return name == advertisedServiceName
            }
            return false
        }
    }

    private func firePathSatisfied() { onPathSatisfied?() }

    func stop() {
        listener.cancel()
        browser.cancel()
        pathMonitor.cancel()
        log.info("Stopped network discovery and advertisement")
    }

    // Re-create ONLY the listener on a fresh ephemeral port and re-advertise.
    // Connections already vended to newConnectionHandler are independent and
    // are intentionally left running, so re-registering never drops a live
    // MCP session — the persistent session keeps its iMCP connection across a
    // self-heal.
    func restartWithRandomPort() async throws {
        let currentStateHandler = listener.stateUpdateHandler
        let currentConnectionHandler = listener.newConnectionHandler
        let currentRegistrationHandler = listener.serviceRegistrationUpdateHandler

        listener.cancel()

        let newListener = try Self.makeListener(
            serviceType: serviceType,
            serviceDomain: serviceDomain
        )
        newListener.stateUpdateHandler = currentStateHandler
        newListener.newConnectionHandler = currentConnectionHandler
        newListener.serviceRegistrationUpdateHandler = currentRegistrationHandler
        newListener.start(queue: queue)

        self.listener = newListener
        advertisedServiceName = nil  // re-learned from the new registration
        ownServiceVisible = false  // re-confirmed by the browser within ~1-2s

        log.notice("Re-registered Bonjour advertisement with a fresh listener")
    }
}

actor ServerNetworkManager {
    private var isRunningState: Bool = false
    private var isEnabledState: Bool = true
    private var discoveryManager: NetworkDiscoveryManager?
    private var connections: [UUID: MCPConnectionManager] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingConnections: [UUID: String] = [:]
    private var removedConnections: Set<UUID> = []

    typealias ConnectionApprovalHandler = @Sendable (UUID, MCP.Client.Info) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    private let services = ServiceRegistry.services
    private var serviceBindings: [String: Binding<Bool>] = [:]

    // Debounce counter for the advertisement health monitor.
    private var consecutiveUnhealthyChecks = 0

    init() {
        do {
            self.discoveryManager = try NetworkDiscoveryManager(
                serviceType: serviceType,
                serviceDomain: serviceDomain
            )
        } catch {
            log.error("Failed to initialize network discovery manager: \(error)")
        }
    }

    func isRunning() -> Bool {
        isRunningState
    }

    func setConnectionApprovalHandler(_ handler: @escaping ConnectionApprovalHandler) {
        log.debug("Setting connection approval handler")
        self.connectionApprovalHandler = handler
    }

    func start() async {
        // Guard against re-entry: a second start() would spawn a duplicate
        // health-monitor loop and re-wire handlers.
        guard !isRunningState else {
            log.info("Network manager already running")
            return
        }

        log.info("Starting network manager")
        isRunningState = true

        guard let discoveryManager = discoveryManager else {
            log.error("Cannot start network manager: discovery manager not initialized")
            return
        }

        // A network-path transition (sleep/wake, network change) is a strong
        // hint the Bonjour registration may have been dropped — verify and heal.
        await discoveryManager.setOnPathSatisfied { [weak self] in
            guard let self else { return }
            Task { await self.checkAndHealAdvertisement(reason: "path-satisfied") }
        }

        await discoveryManager.start(
            stateHandler: { [weak self] (state: NWListener.State) -> Void in
                guard let strongSelf = self else { return }

                Task {
                    await strongSelf.handleListenerStateChange(state)
                }
            },
            connectionHandler: { [weak self] (connection: NWConnection) -> Void in
                guard let strongSelf = self else { return }

                Task {
                    await strongSelf.handleNewConnection(connection)
                }
            }
        )

        // Health monitor: verify the advertisement is genuinely live — not just
        // that the listener object self-reports `.ready`.
        Task {
            while self.isRunningState {
                await self.checkAndHealAdvertisement(reason: "monitor")
                try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10s
            }
        }
    }

    // Single recovery path for advertisement health. Re-registers the listener
    // when it is definitively dead (.failed/.cancelled), stuck non-ready, or
    // self-reports `.ready` while the browser cannot see our service. The
    // re-register preserves all live connections (see restartWithRandomPort).
    private func checkAndHealAdvertisement(reason: String) async {
        guard isRunningState, let dm = discoveryManager else { return }

        let state = await dm.currentListenerState()
        let visible = await dm.isOwnServiceVisible()

        let definitelyDead: Bool
        let healthy: Bool
        switch state {
        case .ready:
            definitelyDead = false
            healthy = visible  // ready AND actually discoverable
        case .failed, .cancelled:
            definitelyDead = true
            healthy = false
        default:  // .setup, .waiting, and any future states
            definitelyDead = false
            healthy = false
        }

        if healthy {
            consecutiveUnhealthyChecks = 0
            return
        }

        consecutiveUnhealthyChecks += 1
        let strikes = consecutiveUnhealthyChecks
        let stateText = String(describing: state)
        log.warning(
            "Advertisement unhealthy (reason: \(reason), state: \(stateText), visible: \(visible), strike \(strikes))"
        )

        // Act immediately on a definitively dead listener or a path transition;
        // otherwise require sustained unhealthiness so a single transient
        // browser/listener blip never churns Bonjour. Re-register is itself
        // connection-safe, so the bar is about avoiding needless re-advertise.
        let softThreshold = 3
        guard definitelyDead || reason == "path-satisfied" || consecutiveUnhealthyChecks >= softThreshold
        else { return }

        let liveConnections = connections.count
        log.notice(
            "Re-registering Bonjour advertisement (reason: \(reason)); \(liveConnections) live MCP connection(s) preserved"
        )
        do {
            try await dm.restartWithRandomPort()
            consecutiveUnhealthyChecks = 0
        } catch {
            log.error("Failed to re-register advertisement: \(error.localizedDescription)")
        }
    }

    // Observe-only. Recovery is centralized in `checkAndHealAdvertisement`
    // (driven by the 10s monitor + path-satisfied events) so there is exactly
    // one re-registration driver and no racing restarts.
    private func handleListenerStateChange(_ state: NWListener.State) async {
        switch state {
        case .ready:
            log.info("Server ready and advertising via Bonjour as \(serviceType)")
        case .setup:
            log.debug("Server setting up...")
        case .waiting(let error):
            log.warning("Server waiting: \(error) — monitor will re-register if it persists")
        case .failed(let error):
            log.error("Server failed: \(error) — monitor will re-register")
        case .cancelled:
            log.info("Server listener cancelled")
        @unknown default:
            log.warning("Unknown server state")
        }
    }

    func stop() async {
        log.info("Stopping network manager")
        isRunningState = false

        for (id, connectionManager) in connections {
            log.debug("Stopping connection: \(id)")
            await connectionManager.stop()
            connectionTasks[id]?.cancel()
        }

        connections.removeAll()
        connectionTasks.removeAll()
        pendingConnections.removeAll()
        removedConnections.removeAll()

        await discoveryManager?.stop()
    }

    func removeConnection(_ id: UUID) async {
        // Guard against redundant removal — calling stop() on an already-stopped
        // connection can trigger a double-resume in the SDK's transport continuation.
        guard !removedConnections.contains(id) else {
            log.debug("Connection \(id) already removed, skipping")
            return
        }
        removedConnections.insert(id)

        log.debug("Removing connection: \(id)")

        if let connectionManager = connections[id] {
            await connectionManager.stop()
        }

        if let task = connectionTasks[id] {
            task.cancel()
        }

        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
        pendingConnections.removeValue(forKey: id)
    }

    // Handle new incoming connections.
    private func handleNewConnection(_ connection: NWConnection) async {
        let connectionID = UUID()
        log.info("Handling new connection: \(connectionID)")

        let connectionManager = MCPConnectionManager(
            connectionID: connectionID,
            connection: connection,
            parentManager: self
        )

        connections[connectionID] = connectionManager

        // Drive the MCP handshake and approval flow.
        let task = Task {
            // Ensure this task is removed so the timeout logic doesn't fire afterward.
            defer {
                self.connectionTasks.removeValue(forKey: connectionID)
            }

            do {
                guard let approvalHandler = self.connectionApprovalHandler else {
                    log.error("No connection approval handler set, rejecting connection")
                    await removeConnection(connectionID)
                    return
                }

                try await connectionManager.start { clientInfo in
                    await approvalHandler(connectionID, clientInfo)
                }

                log.notice("Connection \(connectionID) successfully established")
            } catch {
                log.error("Failed to establish connection \(connectionID): \(error)")
                await removeConnection(connectionID)
            }
        }

        connectionTasks[connectionID] = task

        // Time out stalled setups to avoid orphaned connections.
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds

            // If the setup task is still registered, treat it as timed out.
            if self.connectionTasks[connectionID] != nil,
                self.connections[connectionID] != nil
            {
                log.warning(
                    "Connection \(connectionID) setup timed out (task still in registry), closing it"
                )
                await removeConnection(connectionID)
            }
        }
    }

    func registerHandlers(for server: MCP.Server, connectionID: UUID) async {
        await server.withMethodHandler(ListPrompts.self) { _ in
            log.debug("Handling ListPrompts request for \(connectionID)")
            return ListPrompts.Result(prompts: [])
        }

        await server.withMethodHandler(ListResources.self) { _ in
            log.debug("Handling ListResources request for \(connectionID)")
            return ListResources.Result(resources: [])
        }

        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self = self else {
                return ListTools.Result(tools: [])
            }

            log.debug("Handling ListTools request for \(connectionID)")

            var tools: [MCP.Tool] = []
            if await self.isEnabledState {
                for service in await self.services {
                    let serviceId = String(describing: type(of: service))

                    // Read binding on the actor for consistency.
                    if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                        isServiceEnabled
                    {
                        for tool in service.tools {
                            log.debug("Adding tool: \(tool.name)")
                            tools.append(
                                .init(
                                    name: tool.name,
                                    description: tool.description,
                                    inputSchema: try Value(tool.inputSchema),
                                    annotations: tool.annotations
                                )
                            )
                        }
                    }
                }
            }

            log.info("Returning \(tools.count) available tools for \(connectionID)")
            return ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(
                    content: [.text(text: "Server unavailable", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            log.notice("Tool call received from \(connectionID): \(params.name)")

            guard await self.isEnabledState else {
                log.notice("Tool call rejected: iMCP is disabled")
                return CallTool.Result(
                    content: [
                        .text(
                            text: "iMCP is currently disabled. Please enable it to use tools.",
                            annotations: nil,
                            _meta: nil
                        )
                    ],
                    isError: true
                )
            }

            for service in await self.services {
                let serviceId = String(describing: type(of: service))

                // Read binding on the actor for consistency.
                if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                    isServiceEnabled
                {
                    do {
                        guard
                            let value = try await service.call(
                                tool: params.name,
                                with: params.arguments ?? [:]
                            )
                        else {
                            continue
                        }

                        log.notice("Tool \(params.name) executed successfully for \(connectionID)")
                        switch value {
                        case .data(let mimeType?, let data) where mimeType.hasPrefix("audio/"):
                            return CallTool.Result(
                                content: [
                                    .audio(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType,
                                        annotations: nil,
                                        _meta: nil
                                    )
                                ],
                                isError: false
                            )
                        case .data(let mimeType?, let data) where mimeType.hasPrefix("image/"):
                            return CallTool.Result(
                                content: [
                                    .image(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType,
                                        annotations: nil,
                                        _meta: nil
                                    )
                                ],
                                isError: false
                            )
                        default:
                            let encoder = JSONEncoder()
                            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
                                TimeZone.current
                            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

                            let data = try encoder.encode(value)
                            let text = String(data: data, encoding: .utf8)!

                            return CallTool.Result(
                                content: [.text(text: text, annotations: nil, _meta: nil)],
                                isError: false
                            )
                        }
                    } catch {
                        log.error(
                            "Error executing tool \(params.name): \(error.localizedDescription)"
                        )
                        return CallTool.Result(
                            content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                }
            }

            log.error("Tool not found or service not enabled: \(params.name)")
            return CallTool.Result(
                content: [
                    .text(text: "Tool not found or service not enabled: \(params.name)", annotations: nil, _meta: nil)
                ],
                isError: true
            )
        }
    }

    // Update the enabled state and notify clients.
    func setEnabled(_ enabled: Bool) async {
        // Only act on changes.
        guard isEnabledState != enabled else { return }

        isEnabledState = enabled
        log.info("iMCP enabled state changed to: \(enabled)")

        // Notify all connected clients that the tool list has changed.
        for (_, connectionManager) in connections {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    // Update service bindings.
    func updateServiceBindings(_ newBindings: [String: Binding<Bool>]) async {
        self.serviceBindings = newBindings

        // Notify clients that tool availability may have changed.
        Task {
            for (_, connectionManager) in connections {
                await connectionManager.notifyToolListChanged()
            }
        }
    }
}
