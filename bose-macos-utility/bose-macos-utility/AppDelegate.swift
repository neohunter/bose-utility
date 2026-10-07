import Cocoa
import IOBluetooth
import OSLog

@main
class AppDelegate: NSObject, NSApplicationDelegate, IOBluetoothRFCOMMChannelDelegate {
    var statusBarItem: NSStatusItem!
    let headphonesMenu = NSMenu()
    let sourcesMenu = NSMenu()
    let noiseMenu = NSMenu()
    var channel: IOBluetoothRFCOMMChannel?
    var parser = BoseProtocol()
    var sources: [BoseSource] = []
    var expectedAddresses: [[UInt8]] = []
    var timeout: Timer?
    var pending: (command: UInt8, address: [UInt8])?
    var connecting = false
    var selectedDevice: IOBluetoothDevice?
    var connectionState = "Not connected"
    let logger = OSLog(subsystem: "lukasz-zet.bose-macos-utility", category: "Connection")

    func log(_ message: String) {
        os_log("%{public}@", log: logger, type: .default, message)
    }

    func updateSelection(_ state: String) {
        connectionState = state
        statusBarItem.button?.toolTip = selectedDevice.map { "\($0.nameOrAddress ?? "Bose"): \(state)" } ?? state
        for item in headphonesMenu.items {
            guard let device = item.representedObject as? IOBluetoothDevice else { continue }
            let selected = device.addressString == selectedDevice?.addressString
            item.state = selected ? .on : .off
            item.title = (device.nameOrAddress ?? "Unknown device") + (selected ? " — \(state)" : "")
        }
        log("Connection state: \(state)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem.button?.title = "🎧"
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, submenu) in [("Select headphones", headphonesMenu),
                                  ("Headphone connections", sourcesMenu),
                                  ("Noise cancellation", noiseMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            submenu.autoenablesItems = false
            menu.addItem(item)
        }
        for (title, value) in [("Off", 0), ("Medium", 3), ("High", 1)] {
            let item = actionItem(title, #selector(changeNoise(_:)))
            item.tag = value
            noiseMenu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("About Bose Utility", #selector(showAbout)))
        menu.addItem(actionItem("Quit", #selector(quit)))
        headphonesMenu.showsStateColumn = true
        statusBarItem.menu = menu
        refreshHeadphones()
        showStatus("Select your Bose headphones first")
        // Reuse the control host's already connected Bose; do not change source connections.
        let connectedBose = headphonesMenu.items.filter {
            guard let device = $0.representedObject as? IOBluetoothDevice else { return false }
            return device.isConnected() && (device.name ?? "").localizedCaseInsensitiveContains("bose")
        }
        if connectedBose.count == 1 {
            DispatchQueue.main.async { self.selectHeadphones(connectedBose[0]) }
        }
    }

    func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func showStatus(_ text: String) {
        log("Status: \(text)")
        sourcesMenu.removeAllItems()
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        sourcesMenu.addItem(item)
        sourcesMenu.addItem(actionItem("Refresh connections", #selector(refreshConnections)))
    }

    @objc func refreshHeadphones() {
        headphonesMenu.removeAllItems()
        headphonesMenu.addItem(actionItem("Refresh headphones", #selector(refreshHeadphones)))
        headphonesMenu.addItem(.separator())
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        for device in devices {
            let item = actionItem(device.nameOrAddress ?? "Unknown device", #selector(selectHeadphones(_:)))
            item.representedObject = device
            headphonesMenu.addItem(item)
        }
        updateSelection(connectionState)
    }

    @objc func selectHeadphones(_ sender: NSMenuItem) {
        guard !connecting, let device = sender.representedObject as? IOBluetoothDevice else { return }
        connecting = true
        timeout?.invalidate()
        pending = nil
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        parser = BoseProtocol()
        sources = []
        selectedDevice = device
        updateSelection("Connecting…")
        showStatus("Looking up Bose Bluetooth services…")
        startTimeout("Bluetooth service lookup timed out; select headphones again")
        let result = device.performSDPQuery(self)
        log("SDP started: \(result)")
        if result != kIOReturnSuccess {
            connecting = false
            timeout?.invalidate()
            updateSelection("Connection failed")
            showStatus("Bluetooth service lookup failed (\(result))")
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let device = device, connecting,
              device.addressString == selectedDevice?.addressString else { return }
        log("SDP completed: \(status)")
        timeout?.invalidate()
        guard status == kIOReturnSuccess,
              let services = device.services as? [IOBluetoothSDPServiceRecord],
              let service = services.first(where: { $0.getServiceName() == "SPP Dev" })
                ?? services.first(where: { $0.matchesUUID16(0x1101) }) else {
            connecting = false
            updateSelection("Connection failed")
            showStatus(status == kIOReturnSuccess ? "No compatible Bose service found" : "Bluetooth lookup failed (\(status))")
            return
        }
        log("Bose service found by name or Serial Port UUID")
        var id: BluetoothRFCOMMChannelID = 0
        guard service.getRFCOMMChannelID(&id) == kIOReturnSuccess else {
            connecting = false
            updateSelection("Connection failed")
            showStatus("Cannot find the Bose control channel")
            return
        }
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelSync(&opened, withChannelID: id, delegate: self)
        log("RFCOMM open: \(result)")
        connecting = false
        guard result == kIOReturnSuccess, let opened = opened else {
            updateSelection("Connection failed")
            showStatus("Control connection failed (\(result)); reconnect headphones")
            return
        }
        channel = opened
        // Initialize the BMAP control session, then request the saved sources.
        updateSelection("Connected")
        showStatus("Initializing Bose control session…")
        startTimeout("Bose control session did not respond; select headphones again")
        if !send([0, 1, 1, 0]) { timeout?.invalidate() }
    }

    @discardableResult func send(_ bytes: [UInt8]) -> Bool {
        guard let channel = channel, channel.isOpen() else {
            showStatus("Headphones disconnected; select them again")
            return false
        }
        var bytes = bytes
        let count = UInt16(bytes.count)
        log("Sending group \(bytes[0]), command \(bytes[1])")
        let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress!, length: count) }
        log("Bluetooth write result: \(result), MTU: \(channel.getMTU())")
        guard result == kIOReturnSuccess else {
            showStatus("Bluetooth command failed (\(result)); refresh or reconnect")
            return false
        }
        return true
    }

    func startTimeout(_ message: String) {
        timeout?.invalidate()
        timeout = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
            self?.connecting = false
            if self?.channel == nil { self?.updateSelection("Connection failed") }
            self?.pending = nil
            self?.showStatus(message)
        }
        RunLoop.main.add(timeout!, forMode: .common)
    }

    @objc func refreshConnections() {
        guard pending == nil else { return }
        sources = []
        expectedAddresses = []
        showStatus("Reading headphone connections…")
        startTimeout("No response; refresh or reconnect your headphones")
        if !send([4, 4, 1, 0]) { timeout?.invalidate() }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let rfcommChannel = rfcommChannel, rfcommChannel === channel,
              let dataPointer = dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        // IOBluetooth delivers callbacks on the application's run loop.
        for frame in parser.receive(bytes) { handle(frame) }
    }

    func handle(_ frame: BoseFrame) {
        log("Received group \(frame.group), command \(frame.command), kind \(frame.kind), length \(frame.payload.count)")
        if frame.group == 0, frame.command == 1, frame.kind == 3 {
            timeout?.invalidate()
            refreshConnections()
            return
        }
        guard frame.group == 4 else { return }
        if let action = pending, frame.command == action.command,
           frame.kind == 7, frame.payload == action.address {
            pending = nil
            timeout?.invalidate()
            refreshConnections()
        } else if frame.command == 4, frame.kind == 3,
                  let addresses = BoseProtocol.addresses(frame.payload) {
            expectedAddresses = addresses
            sources = []
            if addresses.isEmpty {
                timeout?.invalidate()
                showStatus("No saved devices reported by headphones")
            } else {
                for address in addresses { _ = send([4, 5, 1, 6] + address) }
            }
        } else if frame.command == 5, frame.kind == 3,
                  let source = BoseSource.parse(frame.payload),
                  expectedAddresses.contains(source.address) {
            sources.removeAll { $0.address == source.address }
            sources.append(source)
            renderSources()
            if sources.count == expectedAddresses.count { timeout?.invalidate() }
        }
    }

    func renderSources() {
        sourcesMenu.removeAllItems()
        for source in sources {
            let connected = source.status == 1 || source.status == 3
            let known = [UInt8(0), 1, 3].contains(source.status)
            let suffix = source.status == 3 ? " (this Mac)" : (connected ? " (connected)" : (known ? "" : " (unknown state)"))
            let item = NSMenuItem(title: source.name + suffix, action: nil, keyEquivalent: "")
            item.state = connected ? .on : .off
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let action = actionItem(connected ? "Disconnect" : "Connect", #selector(changeConnection(_:)))
            action.representedObject = source
            action.isEnabled = known && pending == nil
            submenu.addItem(action)
            item.submenu = submenu
            sourcesMenu.addItem(item)
        }
        if sources.count < expectedAddresses.count {
            let item = NSMenuItem(title: "Reading remaining devices…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            sourcesMenu.addItem(item)
        }
        sourcesMenu.addItem(.separator())
        sourcesMenu.addItem(actionItem("Refresh connections", #selector(refreshConnections)))
    }

    @objc func changeConnection(_ sender: NSMenuItem) {
        guard pending == nil, let source = sender.representedObject as? BoseSource else { return }
        let connected = source.status == 1 || source.status == 3
        let packet = connected ? BoseProtocol.disconnect(source.address) : BoseProtocol.connect(source.address)
        guard let packet = packet else { return }
        pending = (connected ? 2 : 1, source.address)
        showStatus(connected ? "Disconnecting \(source.name)…" : "Connecting to \(source.name)…")
        startTimeout("Change not confirmed; refresh connections")
        if !send(packet) { pending = nil; timeout?.invalidate() }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard let rfcommChannel = rfcommChannel, rfcommChannel === channel else { return }
        timeout?.invalidate()
        pending = nil
        channel = nil
        updateSelection("Disconnected")
        showStatus("Control connection closed; select headphones again")
    }

    @objc func changeNoise(_ sender: NSMenuItem) {
        _ = send([1, 6, 2, 1, UInt8(sender.tag)])
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Bose Utility",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(string: "Created by Arnold Roa\n\nBose is a trademark of Bose Corporation.")
        ])
    }

    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        timeout?.invalidate()
        channel?.setDelegate(nil)
        channel?.close()
    }
}
