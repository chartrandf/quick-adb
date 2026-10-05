import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shell

struct ShellResult {
    let status: Int32
    let output: String
}

@discardableResult
func run(_ path: String, _ args: [String]) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ShellResult(status: -1, output: "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ShellResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

// Binary stdout (e.g. screencap PNG) kept apart from stderr.
func runData(_ path: String, _ args: [String]) -> (status: Int32, data: Data, error: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return (-1, Data(), "\(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data, String(decoding: errData, as: UTF8.self))
}

// GUI apps don't inherit the shell PATH, so look in the usual places.
let home = NSHomeDirectory()
let sdkRoots = [ProcessInfo.processInfo.environment["ANDROID_HOME"], "\(home)/Library/Android/sdk"].compactMap { $0 }

func firstExecutable(_ candidates: [String]) -> String? {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func findAdb() -> String? {
    firstExecutable(["/opt/homebrew/bin/adb", "/usr/local/bin/adb"] + sdkRoots.map { "\($0)/platform-tools/adb" })
}

func findAapt2() -> String? {
    for root in sdkRoots {
        let dir = "\(root)/build-tools"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        if let hit = firstExecutable(sorted.map { "\(dir)/\($0)/aapt2" }) { return hit }
    }
    return firstExecutable(["/opt/homebrew/bin/aapt2", "/usr/local/bin/aapt2"])
}

func packageName(of apk: URL) -> String? {
    if let aapt2 = findAapt2() {
        let r = run(aapt2, ["dump", "packagename", apk.path])
        if r.status == 0, !r.output.isEmpty { return r.output }
    }
    if let analyzer = firstExecutable(["/opt/homebrew/bin/apkanalyzer", "/usr/local/bin/apkanalyzer"]) {
        let r = run(analyzer, ["manifest", "application-id", apk.path])
        if r.status == 0, !r.output.isEmpty { return r.output.components(separatedBy: "\n").last }
    }
    return nil
}

struct Device {
    let serial: String
    let name: String // e.g. "Google Pixel 8a"
    var slug: String { name.lowercased().replacingOccurrences(of: " ", with: "-") }
}

// `adb devices -l` gives the model; the manufacturer needs a getprop.
func connectedDevices(adb: String) -> [Device] {
    run(adb, ["devices", "-l"]).output
        .components(separatedBy: "\n")
        .dropFirst()
        .compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            let serial = String(parts[0])
            let model = parts.first { $0.hasPrefix("model:") }
                .map { $0.dropFirst(6).replacingOccurrences(of: "_", with: " ") } ?? serial
            let maker = run(adb, ["-s", serial, "shell", "getprop", "ro.product.manufacturer"]).output
            let name = maker.isEmpty || model.lowercased().hasPrefix(maker.lowercased()) ? model : "\(maker) \(model)"
            return Device(serial: serial, name: name)
        }
}

// MARK: - Window

enum WindowState {
    case idle, busy, waiting, success, failure

    var symbol: String {
        switch self {
        case .idle, .busy: return "ant.fill"
        case .waiting: return "cable.connector"
        case .success: return "checkmark"
        case .failure: return "xmark"
        }
    }

    var colors: [Color] {
        switch self {
        case .idle, .busy: return [Color(red: 0.36, green: 0.89, blue: 0.56), Color(red: 0.13, green: 0.66, blue: 0.40)]
        case .waiting: return [.orange, Color(red: 0.92, green: 0.45, blue: 0.10)]
        case .success: return [Color(red: 0.36, green: 0.89, blue: 0.56), Color(red: 0.13, green: 0.66, blue: 0.40)]
        case .failure: return [Color(red: 1, green: 0.45, blue: 0.42), Color(red: 0.85, green: 0.18, blue: 0.20)]
        }
    }
}

final class StatusModel: ObservableObject {
    @Published var state: WindowState = .idle
    @Published var title = ""
    @Published var subtitle = ""
    @Published var log = ""
    @Published var pushEnabled = false
    @Published var detailsOpen = true
    @Published var dropTargeted = false
}

let brandGreen = Color(red: 0.13, green: 0.66, blue: 0.40)

struct StatusView: View {
    @ObservedObject var model: StatusModel
    let onPush: () -> Void
    let onClose: () -> Void
    let onDrop: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            iconTile
                .padding(.top, 34)
                .padding(.bottom, 14)

            Text(model.dropTargeted ? "Release to install" : model.title)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            if !model.subtitle.isEmpty {
                Text(model.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 4)
            }

            Group {
                if model.state == .busy {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                        .frame(height: 44)
                } else if model.pushEnabled {
                    Button(action: onPush) {
                        Label(model.state == .failure ? "Retry" : "Push to device",
                              systemImage: model.state == .failure ? "arrow.clockwise" : "arrow.down.to.line")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .frame(height: 44)
                            .background(Capsule().fill(model.state == .failure ? Color.red : brandGreen))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 18)

            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)

            // No APK sent yet: nothing to show.
            if model.state != .idle {
                details
                    .padding(.top, 16)
            }

            // Esc closes.
            Button("", action: onClose).keyboardShortcut(.cancelAction).hidden().frame(height: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(width: 440)
        .background(
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(dropHighlight)
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted, perform: handleDrop)
    }

    // Dashed green frame while an APK hovers over the window.
    @ViewBuilder var dropHighlight: some View {
        if model.dropTargeted {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(brandGreen.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(brandGreen, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.state != .busy, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "apk" else { return }
            DispatchQueue.main.async { onDrop(url) }
        }
        return true
    }

    var caption: String {
        if model.dropTargeted { return "It will be pushed to the connected device." }
        switch model.state {
        case .busy: return "Sending over adb…"
        case .waiting: return "Plug in a phone with USB debugging on."
        case .failure: return "See the details below."
        case .success: return "App launched on the device."
        case .idle: return "You can also drop it on the ant in the menu bar."
        }
    }

    var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(white: 0.92)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.black.opacity(0.06))
            if model.dropTargeted {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(brandGreen)
            } else if model.state == .busy {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: model.state.symbol)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: model.state.colors, startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(width: 64, height: 64)
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.detailsOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(model.detailsOpen ? 90 : 0))
                    Text("Details").font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.detailsOpen {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.isEmpty ? "No output yet." : model.log)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(model.log.isEmpty ? .tertiary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 200)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                    .onReceive(model.$log) { _ in DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

final class StatusWindow: NSObject {
    let window: NSPanel
    let model = StatusModel()
    var onPush: (() -> Void)?
    var onDrop: ((URL) -> Void)?
    var file: URL?
    var package: String?
    var state: WindowState { model.state }
    var title: String {
        get { model.title }
        set { model.title = newValue }
    }

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Quick ADB"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false // panels hide when the app is inactive, which a menu bar app often is

        let host = NSHostingController(rootView: StatusView(model: model,
                                                            onPush: { [weak self] in self?.onPush?() },
                                                            onClose: { [weak self] in self?.close() },
                                                            onDrop: { [weak self] in self?.onDrop?($0) }))
        host.sizingOptions = .preferredContentSize // window follows the SwiftUI size
        window.contentViewController = host
    }

    func show(_ state: WindowState, _ title: String, pushEnabled: Bool = false) {
        model.state = state
        model.title = title
        model.subtitle = [file?.lastPathComponent, package].compactMap { $0 }.joined(separator: "  ·  ")
        model.pushEnabled = pushEnabled
        if state == .failure { model.detailsOpen = true }

        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func clearLog() { model.log = "" }
    func log(_ text: String) { model.log += text + "\n" }
    func setDetails(visible: Bool) { model.detailsOpen = visible }
    @objc func close() { window.orderOut(nil) }
}

// MARK: - Drop target

// Transparent view laid over the status item button. It takes the drags; clicks go on to the button (menu).
final class DropView: NSView {
    var onEnter: ((NSDraggingInfo) -> NSDragOperation)?
    var onExit: (() -> Void)?
    var onDrop: ((NSDraggingInfo) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onEnter?(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?(sender) ?? false }

    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let statusWindow = StatusWindow()
    var pendingApk: URL?
    var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(filled: false)

        if let button = statusItem.button {
            let drop = DropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onEnter = { [weak self] in self?.draggingEntered($0) ?? [] }
            drop.onExit = { [weak self] in self?.draggingExited() }
            drop.onDrop = { [weak self] in self?.performDragOperation($0) ?? false }
            button.addSubview(drop)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Install APK…", action: #selector(pickApk), keyEquivalent: "o")
        menu.addItem(withTitle: "Show window", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        let logItem = menu.addItem(withTitle: "Capture log", action: nil, keyEquivalent: "")
        logItem.submenu = NSMenu()
        logItem.submenu?.delegate = self
        let shotItem = menu.addItem(withTitle: "Take screenshot", action: nil, keyEquivalent: "")
        shotItem.submenu = NSMenu()
        shotItem.submenu?.delegate = self
        screenshotMenu = shotItem.submenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        statusWindow.onPush = { [weak self] in self?.install() }
        statusWindow.onDrop = { [weak self] url in
            self?.pendingApk = url
            self?.install()
        }
        statusWindow.title = "Drop an APK here"
    }

    // Highlight the button while an APK is dragged over it.
    func setIcon(filled: Bool) {
        statusItem.button?.title = ""
        statusItem.button?.image = NSImage(systemSymbolName: "ant.fill", accessibilityDescription: "Quick ADB")
        statusItem.button?.highlight(filled)
    }

    // Shows a ✅ (or ❌) in the menu bar for a few seconds.
    func flash(_ emoji: String) {
        statusItem.button?.image = nil
        statusItem.button?.title = emoji
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.setIcon(filled: false) }
    }

    // MARK: Drag & drop

    func apkURL(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.first { $0.pathExtension.lowercased() == "apk" }
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard apkURL(from: sender) != nil else { return [] }
        setIcon(filled: true)
        return .copy
    }

    func draggingExited() { setIcon(filled: false) }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setIcon(filled: false)
        guard let url = apkURL(from: sender) else { return false }
        pendingApk = url
        install()
        return true
    }

    @objc func pickApk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingApk = url
        install()
    }

    @objc func showWindow() {
        statusWindow.show(statusWindow.state, statusWindow.title, pushEnabled: pendingApk != nil)
    }

    // MARK: Log capture (same as the adb-time shell function)

    let logRanges = [1, 2, 3, 4, 5, 10, 15, 30]
    var screenshotMenu: NSMenu?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let devices = findAdb().map(connectedDevices) ?? []
        guard !devices.isEmpty else {
            menu.addItem(withTitle: "No device connected", action: nil, keyEquivalent: "")
            return
        }
        if menu === screenshotMenu {
            for device in devices {
                let item = menu.addItem(withTitle: device.name, action: #selector(takeScreenshot(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
            }
            return
        }
        let addRanges: (NSMenu, Device) -> Void = { target, device in
            for minutes in self.logRanges {
                let item = target.addItem(withTitle: "Last \(minutes) min", action: #selector(self.captureLog(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (device, minutes)
            }
        }
        if devices.count == 1 {
            let header = menu.addItem(withTitle: devices[0].name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            addRanges(menu, devices[0])
        } else {
            for device in devices {
                let item = menu.addItem(withTitle: device.name, action: nil, keyEquivalent: "")
                item.submenu = NSMenu()
                addRanges(item.submenu!, device)
            }
        }
    }

    @objc func captureLog(_ item: NSMenuItem) {
        guard let (device, minutes) = item.representedObject as? (Device, Int), let adb = findAdb() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm:ss.000"
            let since = fmt.string(from: Date().addingTimeInterval(TimeInterval(-minutes * 60)))
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let file = URL(fileURLWithPath: "\(home)/Desktop/\(device.slug)-\(fmt.string(from: Date())).log")

            let r = run(adb, ["-s", device.serial, "logcat", "-d", "-t", since])
            DispatchQueue.main.async {
                guard r.status == 0, (try? r.output.write(to: file, atomically: true, encoding: .utf8)) != nil else {
                    self.statusWindow.clearLog()
                    self.statusWindow.log(r.output)
                    self.statusWindow.file = nil
                    self.statusWindow.package = nil
                    self.statusWindow.show(.failure, "Log capture failed")
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
    }

    // Same as ~/Desktop/screenshot.sh: adb exec-out screencap -p
    @objc func takeScreenshot(_ item: NSMenuItem) {
        guard let device = item.representedObject as? Device, let adb = findAdb() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let file = URL(fileURLWithPath: "\(home)/Desktop/\(device.slug)-\(fmt.string(from: Date())).png")

            let r = runData(adb, ["-s", device.serial, "exec-out", "screencap", "-p"])
            let isPNG = r.data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            DispatchQueue.main.async {
                guard r.status == 0, isPNG, (try? r.data.write(to: file)) != nil else {
                    self.statusWindow.clearLog()
                    self.statusWindow.log(r.error.isEmpty ? String(decoding: r.data.prefix(2000), as: UTF8.self) : r.error)
                    self.statusWindow.file = nil
                    self.statusWindow.package = nil
                    self.statusWindow.show(.failure, "Screenshot failed")
                    return
                }
                self.flash("📸")
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
    }

    // MARK: Install

    func install() {
        guard let apk = pendingApk, !busy else { return }
        busy = true
        statusWindow.clearLog()
        statusWindow.file = apk
        statusWindow.package = nil
        statusWindow.show(.busy, "Checking devices…")

        DispatchQueue.global(qos: .userInitiated).async {
            let ui: (@escaping () -> Void) -> Void = { block in DispatchQueue.main.async(execute: block) }
            let log: (String) -> Void = { line in ui { self.statusWindow.log(line) } }
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm:ss.SSS"
            let note: (String) -> Void = { log("[\(clock.string(from: Date()))] \($0)") }
            // Runs a tool, logging the command line, its full output, exit code and duration.
            let exec: (String, [String]) -> ShellResult = { tool, args in
                let quoted = args.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
                note("$ \((tool as NSString).lastPathComponent) \(quoted)")
                let start = Date()
                let r = run(tool, args)
                if !r.output.isEmpty { log(r.output.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")) }
                log(String(format: "    → exit %d in %.2fs", r.status, Date().timeIntervalSince(start)))
                return r
            }
            let finish: (WindowState, String) -> Void = { state, title in
                note(title)
                ui {
                    self.busy = false
                    self.statusWindow.show(state, title, pushEnabled: true)
                }
            }

            let size = (try? FileManager.default.attributesOfItem(atPath: apk.path)[.size] as? Int64) ?? 0
            note("APK: \(apk.path)")
            note("Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")

            guard let adb = findAdb() else { return finish(.failure, "adb not found") }
            note("adb: \(adb)")
            _ = exec(adb, ["version"])
            _ = exec(adb, ["devices", "-l"])
            let devices = connectedDevices(adb: adb)
            guard !devices.isEmpty else { return finish(.waiting, "Please connect a device") }
            devices.forEach { note("Device: \($0.name) (serial \($0.serial))") }

            ui { self.statusWindow.show(.busy, "Reading APK…") }
            var pkg: String?
            if let aapt2 = findAapt2() {
                note("aapt2: \(aapt2)")
                note("$ aapt2 dump badging \(apk.lastPathComponent)  (key lines only)")
                let badging = run(aapt2, ["dump", "badging", apk.path])
                let keys = ["package:", "minSdkVersion:", "sdkVersion:", "targetSdkVersion:", "application-label:", "launchable-activity:", "native-code:"]
                log(badging.output.components(separatedBy: "\n").filter { l in keys.contains { l.hasPrefix($0) } }
                    .map { "    " + $0 }.joined(separator: "\n"))
                let first = badging.output.components(separatedBy: "\n").first ?? ""
                pkg = first.range(of: "name='([^']+)'", options: .regularExpression)
                    .map { String(first[$0].dropFirst(6).dropLast()) }
            }
            if pkg == nil { pkg = packageName(of: apk) }
            guard let pkg else {
                note("Install aapt2 (Android SDK build-tools) or apkanalyzer.")
                return finish(.failure, "Could not read package name from APK")
            }
            note("Package: \(pkg)")
            ui { self.statusWindow.package = pkg }

            var failed = false
            for device in devices {
                let serial = device.serial
                log("")
                note("──── \(device.name) (\(serial)) ────")
                _ = exec(adb, ["-s", serial, "shell", "getprop", "ro.build.version.release"])
                _ = exec(adb, ["-s", serial, "shell", "getprop", "ro.build.version.sdk"])
                let before = exec(adb, ["-s", serial, "shell", "dumpsys package \(pkg) | grep -E 'versionName|versionCode|lastUpdateTime' | head -3"])
                note(before.output.isEmpty ? "\(pkg) not installed yet: fresh install" : "\(pkg) already installed: replacing")

                ui { self.statusWindow.show(.busy, "Installing on \(device.name)…") }
                // Replace in place first: keeps the home screen icon and the app data.
                // --install-reason 4 (user request) lets the Pixel launcher add a home icon on fresh installs.
                var inst = exec(adb, ["-s", serial, "install", "-r", "--install-reason", "4", apk.path])

                // Replace failed (e.g. signature mismatch): clean uninstall + install.
                if inst.status != 0 || !inst.output.contains("Success") {
                    note("Replace failed, falling back to uninstall + install (app data and home icon are lost)")
                    ui { self.statusWindow.show(.busy, "Reinstalling on \(device.name)…") }
                    _ = exec(adb, ["-s", serial, "uninstall", pkg])
                    inst = exec(adb, ["-s", serial, "install", "--install-reason", "4", apk.path])
                }
                guard inst.status == 0, inst.output.contains("Success") else {
                    note("Install failed on \(device.name)")
                    failed = true
                    continue
                }
                _ = exec(adb, ["-s", serial, "shell", "dumpsys package \(pkg) | grep -E 'versionName|versionCode|lastUpdateTime' | head -3"])

                ui { self.statusWindow.show(.busy, "Launching on \(device.name)…") }
                _ = exec(adb, ["-s", serial, "shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"])
                note("Done on \(device.name)")
            }

            log("")
            if failed {
                ui { self.flash("❌") }
                return finish(.failure, "Install failed")
            }
            ui { self.flash("✅") }
            finish(.success, devices.count == 1 ? "Installed on \(devices[0].name)" : "Installed on \(devices.count) devices")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
