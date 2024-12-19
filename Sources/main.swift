import AppKit
@preconcurrency import Darwin
import Foundation
import Network
@preconcurrency import ServiceManagement

let dataPointCount = 30

extension NSColor {
    var complementaryColor: NSColor {
        guard let ciColor = CIColor(color: self) else {
            // Default to black as the complementary color for white
            return NSColor.black
        }
        let complementaryRed = 1.0 - ciColor.red
        let complementaryGreen = 1.0 - ciColor.green
        let complementaryBlue = 1.0 - ciColor.blue
        return NSColor(
            red: complementaryRed, green: complementaryGreen, blue: complementaryBlue,
            alpha: ciColor.alpha)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var pingMenuItem: NSMenuItem?
    let appService = SMAppService.mainApp
    var dataPointDict: [String: [Double]] = [
        // Initial values are all 0
        "CPU": Array(repeating: 0, count: dataPointCount),
        "Mem": Array(repeating: 0, count: dataPointCount),
        "Tx": Array(repeating: 0, count: dataPointCount),
        "Rx": Array(repeating: 0, count: dataPointCount),
        "Ping": Array(repeating: 0, count: dataPointCount),
    ]
    // Configurable (including planned) parameters
    var columnWidth = 24  // the width of each column in pixels
    var columnCount = 4  // the number of columns (CPU, Memory, Tx/Rx, Ping RTT)
    var fontSize: CGFloat = 8
    var bytesPerUnit: Double = 1024  // 1 KiB = 1024 B
    var graphColorComplementaryThreshold_Computing: Double = 80  // 80% or more, use complementary color
    var graphColorComplementaryThreshold_Network: Double = 1  // 1 KiB/s or less, use complementary color
    var graphColorComplementaryThreshold_PingRRT: Double = 100  // 100 ms or more, use complementary color
    var graphMaxValueBpsPerUnit: Double = 1024  // The maximum value of the Y-axis of the graph is 1024 KiB = 1 MiB
    var graphMaxValuePingRTTMillisecond: Double = 200  // The maximum value of the Y-axis of the graph is 200 ms
    var currentPingTarget: String = "1.1.1.1"  // Default Ping target

    // For Tx/Rx
    // Record the previous timer execution time and the amount of data sent and received
    var firstInterval: Bool = true
    var previousTimestamp: Date?
    var previousTx: Double = 0
    var previousRx: Double = 0

    // For Ping
    var pingTask: Process?
    var pingQueue = DispatchQueue(label: "com.ping.queue")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create a menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: CGFloat(columnWidth * columnCount))
        if let button = statusItem?.button {
            button.image = createGraphImage(dataSets: dataPointDict)
            button.action = #selector(showMenu)
            button.target = self
        }

        startPingTask()

        // Update periodically
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.updateMenu() }
        }
    }

    @objc func showMenu() {
        let menu = NSMenu()

        pingMenuItem = NSMenuItem(title: "Set Ping Target (Current: \(currentPingTarget))", action: #selector(changePingTarget), keyEquivalent: "")
        menu.addItem(pingMenuItem!)
        menu.addItem(NSMenuItem.separator())  // Separator

        let isRegistered = appService.status == .enabled
        let loginItemTitle = isRegistered ? "Unregister from Login Items" : "Register to Login Items"
        menu.addItem(withTitle: loginItemTitle, action: #selector(toggleLoginItem), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())  // Separator

        menu.addItem(withTitle: "Show Logs in Terminal.app", action: #selector(showLogsInTerminal), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())  // Separator

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc func toggleLoginItem() {
        Task {
            do {
                if appService.status == .enabled {
                    try appService.unregister()
                } else {
                    try appService.register()
                }
                // Update the menu to reflect the new state
                showMenu()
            } catch {
                NSLog("Failed to toggle login item: \(error)")
            }
        }
    }

    @objc func changePingTarget() {
        let alert = NSAlert()
        alert.messageText = "Change Ping Target"
        alert.informativeText = "Enter the new Ping Target (e.g., 1.1.1.1):"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputField.stringValue = currentPingTarget
        alert.accessoryView = inputField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newTarget = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newTarget.isEmpty {
                currentPingTarget = newTarget
                restartPingTask()
            }
        }
        pingMenuItem?.title = "Set Ping Target (Current: \(currentPingTarget))"
    }

    func startPingTask() {
        let pingTarget = currentPingTarget
        pingQueue.async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/sbin/ping")
            task.arguments = ["-i", "1", pingTarget]

            let pipe = Pipe()
            task.standardOutput = pipe
            let handle = pipe.fileHandleForReading

            handle.readabilityHandler = { [weak self] fileHandle in
                guard let self = self else { return }
                let data = fileHandle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else {
                    NSLog("Ping output is empty or could not be decoded")
                    return
                }

                // Parse RTT
                // If the ping result is "Request timeout" or "unreachable", treat the RTT as 9999
                if output.contains("Request timeout") || output.contains("unreachable") {
                    DispatchQueue.main.async {
                        self.dataPointDict["Ping"]!.append(9999)
                        if self.dataPointDict["Ping"]!.count > dataPointCount {
                            self.dataPointDict["Ping"]!.removeFirst()
                        }
                    }
                } else if let rttString = output.components(separatedBy: "time=").last?.components(separatedBy: " ").first,
                    // If RTT acquisition is successful, convert RTT to Double and save it
                    let rtt = Double(rttString)
                {
                    DispatchQueue.main.async {
                        self.dataPointDict["Ping"]!.append(rtt)
                        if self.dataPointDict["Ping"]!.count > dataPointCount {
                            self.dataPointDict["Ping"]!.removeFirst()
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                self.pingTask = task
            }

            do {
                try task.run()
            } catch {
                NSLog("Failed to start ping process: \(error)")
            }
        }
    }

    func restartPingTask() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTask?.terminate()
            self?.pingTask = nil
            self?.startPingTask()
        }
    }

    @objc func showLogsInTerminal() {
        let script = """
            tell application "Terminal"
                do script "log stream --info --predicate 'process == \\\"MenuBarMonitor\\\"'"
                activate
            end tell
            """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary? = nil
        appleScript?.executeAndReturnError(&error)
        if let error = error {
            NSLog("Failed to execute AppleScript: \(error)")
        }
    }

    func updateMenu() {
        // Get CPU usage
        let cpuUsage = getCPUUsage()
        dataPointDict["CPU"]!.append(cpuUsage)
        if dataPointDict["CPU"]!.count > dataPointCount {
            dataPointDict["CPU"]!.removeFirst()
        }

        // Get memory usage
        let memoryUsage = getMemoryUsage()
        dataPointDict["Mem"]!.append(memoryUsage)
        if dataPointDict["Mem"]!.count > dataPointCount {
            dataPointDict["Mem"]!.removeFirst()
        }

        // Calculate the difference between Tx/Rx
        let currentTimestamp = Date()  // Get the current time
        let elapsedSeconds = previousTimestamp.map { currentTimestamp.timeIntervalSince($0) } ?? 1.0  // Calculate the difference from the previous timer execution time (in seconds)
        previousTimestamp = currentTimestamp
        let (currentTx, currentRx) = getNetworkUsage()
        if firstInterval {
            // To prevent spikes in the graph, treat the previous value as the current value if it is the first run
            previousTx = currentTx
            previousRx = currentRx
            firstInterval = false
        }
        let txDiff = max(0, (currentTx - previousTx) / elapsedSeconds)  // Bps
        let rxDiff = max(0, (currentRx - previousRx) / elapsedSeconds)  // Bps
        previousTx = currentTx
        previousRx = currentRx

        dataPointDict["Tx"]!.append(txDiff)
        if dataPointDict["Tx"]!.count > dataPointCount {
            dataPointDict["Tx"]!.removeFirst()
        }

        dataPointDict["Rx"]!.append(rxDiff)
        if dataPointDict["Rx"]!.count > dataPointCount {
            dataPointDict["Rx"]!.removeFirst()
        }

        // Update Ping RTT data
        // Since it is already being processed on another thread, do nothing here

        // Update the graph
        if let button = statusItem?.button {
            button.image = createGraphImage(dataSets: dataPointDict)
        }

        // Log output
        NSLog(
            "CPU: %6.2f%%, Mem: %6.2f%%, Tx: %8.2f KiB/s, Rx: %8.2f KiB/s, Ping: %7.2f ms",
            cpuUsage,
            memoryUsage, txDiff, rxDiff, dataPointDict["Ping"]!.last ?? 0)
    }

    @objc func quit() {
        NSApplication.shared.terminate(self)
    }

    func getComputingColorScheme(dataPoint: Double) -> (fillColor: NSColor, lineColor: NSColor) {
        let fillColor =
            (dataPoint >= graphColorComplementaryThreshold_Computing)
            ? NSColor.controlAccentColor.complementaryColor.withAlphaComponent(0.3)
            : NSColor.controlAccentColor.withAlphaComponent(0.3)
        let lineColor =
            (dataPoint >= graphColorComplementaryThreshold_Computing)
            ? NSColor.controlAccentColor.complementaryColor : NSColor.controlAccentColor
        return (fillColor, lineColor)
    }

    func getNetworkColorScheme(dataPoint: Double) -> (fillColor: NSColor, lineColor: NSColor) {
        let fillColor =
            (dataPoint <= graphColorComplementaryThreshold_Network)
            ? NSColor.controlAccentColor.complementaryColor.withAlphaComponent(0.3)
            : NSColor.controlAccentColor.withAlphaComponent(0.3)
        let lineColor =
            (dataPoint <= graphColorComplementaryThreshold_Network)
            ? NSColor.controlAccentColor.complementaryColor : NSColor.controlAccentColor
        return (fillColor, lineColor)
    }

    func getPingColorScheme(dataPoint: Double) -> (fillColor: NSColor, lineColor: NSColor) {
        let fillColor =
            (dataPoint >= graphColorComplementaryThreshold_PingRRT)
            ? NSColor.controlAccentColor.complementaryColor.withAlphaComponent(0.3)
            : NSColor.controlAccentColor.withAlphaComponent(0.3)
        let lineColor =
            (dataPoint >= graphColorComplementaryThreshold_PingRRT)
            ? NSColor.controlAccentColor.complementaryColor : NSColor.controlAccentColor
        return (fillColor, lineColor)
    }

    func createGraphImage(dataSets: [String: [Double]]) -> NSImage {
        let menuBarHeight = NSStatusBar.system.thickness
        let width: CGFloat = CGFloat(columnWidth * columnCount)  // Total width
        let height: CGFloat = menuBarHeight  // Match the height of the menu bar
        let graphWidth = CGFloat(columnWidth)  // Total width / number of columns = width of each column (1 is a gap)
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)

        image.lockFocus()

        // Drawing the background
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // Draw a graph for each column

        // 1st column: CPU
        var xOffset: CGFloat = 0
        let (cpuFillColor, cpuLineColor) = getComputingColorScheme(dataPoint: dataSets["CPU"]!.last ?? 0)
        drawFilledLineGraph(data: dataSets["CPU"]!, in: NSRect(x: xOffset, y: 0, width: graphWidth, height: height), maxValue: 100, fillColor: cpuFillColor, lineColor: cpuLineColor)
        drawCenteredText(text: "CPU", in: NSRect(x: xOffset, y: 0, width: graphWidth, height: height), color: NSColor.labelColor)

        // 2nd column: Mem
        xOffset += graphWidth
        let (memFillColor, memLineColor) = getComputingColorScheme(dataPoint: dataSets["Mem"]!.last ?? 0)
        drawFilledLineGraph(data: dataSets["Mem"]!, in: NSRect(x: xOffset, y: 0, width: graphWidth, height: height), maxValue: 100, fillColor: memFillColor, lineColor: memLineColor)
        drawCenteredText(text: "Mem", in: NSRect(x: xOffset, y: 0, width: graphWidth, height: height), color: NSColor.labelColor)

        // 3rd column: Tx (top) Rx (bottom)
        xOffset += graphWidth
        let txMax = max(dataSets["Tx"]!.max() ?? 0, graphMaxValueBpsPerUnit)  // デフォルト 1 MiB を使用
        let txRect = NSRect(x: xOffset, y: height / 2, width: graphWidth, height: height / 2)
        let (txFillColor, txLineColor) = getNetworkColorScheme(dataPoint: dataSets["Tx"]!.last ?? 0)
        drawFilledLineGraph(data: dataSets["Tx"]!, in: txRect, maxValue: txMax, fillColor: txFillColor, lineColor: txLineColor)
        drawCenteredText(text: "Tx", in: txRect, color: NSColor.labelColor)
        let rxMax = max(dataSets["Rx"]!.max() ?? 0, graphMaxValueBpsPerUnit)  // デフォルト 1 MiB を使用
        let rxRect = NSRect(x: xOffset, y: 0, width: graphWidth, height: height / 2)
        let (rxFillColor, rxLineColor) = getNetworkColorScheme(dataPoint: dataSets["Rx"]!.last ?? 0)
        drawFilledLineGraph(data: dataSets["Rx"]!, in: rxRect, maxValue: rxMax, fillColor: rxFillColor, lineColor: rxLineColor)
        drawCenteredText(text: "Rx", in: rxRect, color: NSColor.labelColor)

        // 4th column: Ping RTT
        xOffset += graphWidth
        let maxMillisecond = max(dataSets["Ping"]!.max() ?? 0, graphMaxValuePingRTTMillisecond)  // デフォルト 200ms を使用
        let (pingFillColor, pingLineColor) = getPingColorScheme(dataPoint: dataSets["Ping"]!.last ?? 0)
        drawFilledLineGraph(data: dataSets["Ping"]!, in: NSRect(x: xOffset, y: 0, width: graphWidth, height: height), maxValue: maxMillisecond, fillColor: pingFillColor, lineColor: pingLineColor)
        drawCenteredText(text: "Ping", in: NSRect(x: xOffset, y: 0, width: graphWidth, height: height), color: NSColor.labelColor)

        image.unlockFocus()
        return image
    }

    func drawFilledLineGraph(
        data: [Double], in rect: NSRect, maxValue: Double, fillColor: NSColor, lineColor: NSColor
    ) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.origin.x, y: rect.origin.y))

        // Drawing a line graph
        for (index, value) in data.enumerated() {
            let x = rect.origin.x + CGFloat(index) * (rect.width / CGFloat(data.count))
            let y = rect.origin.y + CGFloat(value) * (rect.height / CGFloat(maxValue))
            path.line(to: CGPoint(x: x, y: y))
        }

        // Close the area
        path.line(to: CGPoint(x: rect.origin.x + rect.width, y: rect.origin.y))  // 右下へ
        path.line(to: CGPoint(x: rect.origin.x, y: rect.origin.y))  // 左下へ
        path.close()

        // Fill
        fillColor.set()
        path.fill()

        // Drawing a line
        lineColor.set()
        path.lineWidth = 0.8
        path.stroke()
    }

    func drawCenteredText(text: String, in rect: NSRect, color: NSColor) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle,
        ]

        let textRect = rect.insetBy(dx: 2, dy: (rect.height - 12) / 2)  // Centering
        text.draw(in: textRect, withAttributes: attributes)
    }

    private var previousCpuInfo: [Double] = []
    func getCPUUsage() -> Double {
        var cpuInfo: processor_info_array_t!
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0
        let CPUUsageLock = NSLock()

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS else {
            // Log output on error and return default value 0
            NSLog("Failed to retrieve CPU usage: \(String(cString: mach_error_string(result)))")
            return 0
        }

        var cpuLoad: [Double] = []
        let cpuInfoArray = Array(UnsafeBufferPointer(start: cpuInfo, count: Int(numCPUInfo)))

        for i in 0..<Int(numCPUs) {
            let baseIndex = Int(CPU_STATE_MAX) * i

            // Get data for each CPU
            let user = Double(cpuInfoArray[baseIndex + Int(CPU_STATE_USER)])
            let system = Double(cpuInfoArray[baseIndex + Int(CPU_STATE_SYSTEM)])
            let nice = Double(cpuInfoArray[baseIndex + Int(CPU_STATE_NICE)])
            let idle = Double(cpuInfoArray[baseIndex + Int(CPU_STATE_IDLE)])

            cpuLoad.append(user)
            cpuLoad.append(system)
            cpuLoad.append(nice)
            cpuLoad.append(idle)
        }

        // Calculate usage
        var overallUsage = 0.0

        if !previousCpuInfo.isEmpty && previousCpuInfo.count == cpuLoad.count {
            var totalDelta = 0.0
            var usedDelta = 0.0

            for i in stride(from: 0, to: cpuLoad.count, by: 4) {
                let userDelta = cpuLoad[i] - previousCpuInfo[i]
                let systemDelta = cpuLoad[i + 1] - previousCpuInfo[i + 1]
                let niceDelta = cpuLoad[i + 2] - previousCpuInfo[i + 2]
                let idleDelta = cpuLoad[i + 3] - previousCpuInfo[i + 3]

                let total = userDelta + systemDelta + niceDelta + idleDelta
                totalDelta += total
                usedDelta += userDelta + systemDelta + niceDelta
            }

            if totalDelta > 0 {
                overallUsage = (Double(usedDelta) / Double(totalDelta)) * 100.0
            }
        }

        CPUUsageLock.lock()
        previousCpuInfo = cpuLoad
        CPUUsageLock.unlock()

        return overallUsage
    }

    func getMemoryUsage() -> Double {
        struct VMStatistics64 {
            var free_count: UInt32 = 0
            var active_count: UInt32 = 0
            var inactive_count: UInt32 = 0
            var wire_count: UInt32 = 0
            var zero_fill_count: UInt32 = 0
            var reactivations: UInt32 = 0
            var pageins: UInt32 = 0
            var pageouts: UInt32 = 0
            var faults: UInt32 = 0
            var cow_faults: UInt32 = 0
            var lookups: UInt32 = 0
            var hits: UInt32 = 0
            var purges: UInt32 = 0
            var purgeable_count: UInt32 = 0
            var speculative_count: UInt32 = 0
            var decompressions: UInt32 = 0
            var compressions: UInt32 = 0
            var swapins: UInt32 = 0
            var swapouts: UInt32 = 0
            var compressor_page_count: UInt32 = 0
            var throttled_count: UInt32 = 0
            var external_page_count: UInt32 = 0
            var internal_page_count: UInt32 = 0
            var total_uncompressed_pages_in_compressor: UInt32 = 0
        }

        let HOST_VM_INFO64: Int32 = 4  // Defined in mach/host_info.h

        var vmStats = VMStatistics64()
        var size = mach_msg_type_number_t(
            MemoryLayout<VMStatistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &vmStats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }

        guard result == KERN_SUCCESS else {
            NSLog("Failed to retrieve memory usage: \(String(cString: mach_error_string(result)))")
            return 0
        }

        // Capture page size
        let pageSize = vm_kernel_page_size

        // Calculate memory usage
        let activeMemory = Double(vmStats.active_count) * Double(pageSize)
        let inactiveMemory = Double(vmStats.inactive_count) * Double(pageSize)
        let wiredMemory = Double(vmStats.wire_count) * Double(pageSize)
        let compressedMemory = Double(vmStats.compressor_page_count) * Double(pageSize)

        let usedMemory = activeMemory + inactiveMemory + wiredMemory + compressedMemory
        // let usedMemory = activeMemory + wiredMemory + compressedMemory
        let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)

        let memoryUsage = (usedMemory / totalMemory) * 100.0

        return memoryUsage
    }

    func getNetworkUsage() -> (txBytes: Double, rxBytes: Double) {
        var txBytes: Double = 0
        var rxBytes: Double = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            NSLog("Failed to retrieve network interfaces.")
            return (txBytes, rxBytes)
        }

        defer {
            freeifaddrs(ifaddr)
        }

        var pointer = firstAddr
        while pointer.pointee.ifa_next != nil {
            let interface = pointer.pointee

            // Check if the interface is AF_LINK (data link layer)
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let data = unsafeBitCast(interface.ifa_data, to: UnsafeMutablePointer<if_data>.self)
                txBytes += Double(data.pointee.ifi_obytes)
                rxBytes += Double(data.pointee.ifi_ibytes)
            }

            pointer = interface.ifa_next!
        }

        return (txBytes / bytesPerUnit, rxBytes / bytesPerUnit)
    }
}

@main
struct MenuBarMonitorApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
