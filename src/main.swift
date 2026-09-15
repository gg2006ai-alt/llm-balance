import AppKit
import Foundation
import Darwin

// MARK: - Balance model

struct ProviderBalance {
    var remaining: Double?
    var usage: Double?
    var limit: Double?

    var ratio: Double? {
        if let r = remaining, let l = limit, l > 0 { return r / l }
        return nil
    }
}

// MARK: - Provider protocol

protocol Provider: AnyObject {
    var name: String { get }
    var keyPrefix: String { get }   // env-file line prefix ending in "="
    var enabled: Bool { get set }
    func fetchBalance(apiKey: String, completion: @escaping (Double?, Double?, Double?, String?) -> Void)
}

// MARK: - Key store

/// App-local key store (UserDefaults). Public version: keys live ONLY in the app,
/// never read from or written to any external/backend file.
final class KeyStore {
    private static func prefKey(for prefix: String) -> String {
        // prefix is like "OPENROUTER_API_KEY=" -> "apiKey.OPENROUTER_API_KEY"
        "apiKey." + prefix.replacingOccurrences(of: "=", with: "")
    }

    /// Returns the key for a provider, or nil when unset/empty.
    static func readKey(prefix: String) -> String? {
        let v = UserDefaults.standard.string(forKey: prefKey(for: prefix))
        return (v == nil || v!.isEmpty) ? nil : v
    }

    /// Stores the key in the app's own UserDefaults.
    static func writeKey(prefix: String, value: String) {
        UserDefaults.standard.set(value, forKey: prefKey(for: prefix))
    }

    // MARK: provider enabled-flag persistence (UserDefaults, survives restarts)
    // The enabled checkbox MUST persist like the key, or every provider resets
    // to disabled on each login (user: "после перезагрузки галочка неактивна").
    private static func flagKey(for prefix: String) -> String {
        "enabled." + prefKey(for: prefix)
    }

    static func readEnabled(prefix: String) -> Bool {
        UserDefaults.standard.string(forKey: flagKey(for: prefix)) == "1"
    }

    static func writeEnabled(prefix: String, on: Bool) {
        UserDefaults.standard.set(on ? "1" : "0", forKey: flagKey(for: prefix))
    }
}

// MARK: - Providers

final class OpenRouterProvider: Provider {
    let name = "OpenRouter"
    let keyPrefix = "OPENROUTER_API_KEY="
    var enabled = false

    func fetchBalance(apiKey: String, completion: @escaping (Double?, Double?, Double?, String?) -> Void) {
            guard let url = URL(string: "https://openrouter.ai/api/v1/credits") else {
                completion(nil, nil, nil, "invalid url"); return
            }
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 30
            URLSession.shared.dataTask(with: req) { data, _, err in
                if let err = err {
                    DispatchQueue.main.async { completion(nil, nil, nil, err.localizedDescription) }; return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let d = json["data"] as? [String: Any] else {
                    DispatchQueue.main.async { completion(nil, nil, nil, "bad response") }; return
                }
                // Real account balance (what the site shows) = total_credits - total_usage.
                let totalCredits = (d["total_credits"] as? NSNumber)?.doubleValue
                let totalUsage = (d["total_usage"] as? NSNumber)?.doubleValue
                var remaining: Double? = nil
                if let tc = totalCredits, let tu = totalUsage {
                    remaining = tc - tu
                }
                DispatchQueue.main.async { completion(remaining, totalUsage, totalCredits, nil) }
            }.resume()
        }
}

final class DeepSeekProvider: Provider {
    let name = "DeepSeek"
    let keyPrefix = "DEEPSEEK_API_KEY="
    var enabled = false

    func fetchBalance(apiKey: String, completion: @escaping (Double?, Double?, Double?, String?) -> Void) {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            completion(nil, nil, nil, "invalid url"); return
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                DispatchQueue.main.async { completion(nil, nil, nil, err.localizedDescription) }; return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let infos = json["balance_infos"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(nil, nil, nil, "bad response") }; return
            }
            var total = 0.0
            var any = false
            for info in infos {
                if let s = info["total_balance"] as? String, let v = Double(s) {
                    total += v
                    any = true
                }
            }
            DispatchQueue.main.async { completion(any ? total : nil, nil, nil, any ? nil : "no balance data") }
        }.resume()
    }
}

// MARK: - Money formatting (top-level helper, used by controller too)

func fmtMoney(_ v: Double?) -> String {
    guard let v = v else { return "$--" }
    return String(format: "$%.2f", v)
}

// MARK: - Settings window controller

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let providers: [Provider]
    private var keyFields: [String: NSTextField] = [:]
    private var secretFields: [String: NSSecureTextField] = [:]
    private var plainFields: [String: NSTextField] = [:]
    private var firstKeyField: NSTextField?
    private var eyeToggles: [String: NSButton] = [:]
    private var pasteButtons: [String: NSButton] = [:]
    private var enabledChecks: [String: NSButton] = [:]
    private var checkButtons: [String: NSButton] = [:]
    private var resultLabels: [String: NSTextField] = [:]
    private var autostartCheck: NSButton?
    var onApply: (() -> Void)?

    private let agentId = "com.stormcore.llmbalance"
    private var autostartPlist: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents").appendingPathComponent(agentId + ".plist").path
    }
    private var appPath: String { Bundle.main.bundlePath }

    init(providers: [Provider]) {
        self.providers = providers
        super.init()
    }

    func showWindow() {
        if window == nil { buildWindow() }
        updateAutostartState()
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            self.window?.center()
            self.window?.makeKeyAndOrderFront(nil)
            if let f = self.firstKeyField { self.window?.makeFirstResponder(f) }
        }
    }

    private func buildWindow() {
        // Height picked to fit exactly: tab bar + 2 provider blocks + Apply bar.
        let winW: CGFloat = 780
        let winH: CGFloat = 336
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "LLM Balance — Settings"
        w.delegate = self
        w.isReleasedWhenClosed = false

        let tab = NSTabView(frame: NSRect(x: 0, y: 48, width: winW, height: winH - 48))
        let pt = NSTabViewItem(identifier: "p")
        pt.label = "Providers"
        pt.view = buildProvidersView()
        let at = NSTabViewItem(identifier: "a")
        at.label = "Autostart"
        at.view = buildAutostartView()
        tab.addTabViewItem(pt)
        tab.addTabViewItem(at)

        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applyPressed))
        applyButton.keyEquivalent = "\r"
        applyButton.frame = NSRect(x: winW - 96, y: 12, width: 84, height: 28)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        container.addSubview(tab)
        container.addSubview(applyButton)
        w.contentView = container
        window = w
    }

    private func buildProvidersView() -> NSView {
        // Deterministic top-to-bottom layout, no auto-layout surprises.
        // The wrapper exactly fills the tab's content area.
        let inset: CGFloat = 20
        let innerW: CGFloat = 712          // content width = window 780 - 2*inset
        let wrapperW: CGFloat = 780
        let wrapperH: CGFloat = 238
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: wrapperW, height: wrapperH))

        // Cursor walks from the TOP of the wrapper downward.
        var yCursor: CGFloat = wrapperH
        var first = true
        for p in providers {
            if !first { yCursor -= 14 }    // spacing between provider blocks
            first = false

            // Provider name (+ optional Enabled toggle on the right)
            let nameLabel = NSTextField(labelWithString: p.name)
            nameLabel.font = NSFont.boldSystemFont(ofSize: 13)
            yCursor -= 20
            nameLabel.frame = NSRect(x: inset, y: yCursor, width: innerW - 110, height: 20)
            wrapper.addSubview(nameLabel)

            let chk = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(enabledToggled(_:)))
            p.enabled = KeyStore.readEnabled(prefix: p.keyPrefix)
            chk.state = p.enabled ? .on : .off
            chk.controlSize = .regular
            chk.font = NSFont.systemFont(ofSize: 11)
            chk.frame = NSRect(x: inset + innerW - 108, y: yCursor - 1, width: 108, height: 20)
            enabledChecks[p.name] = chk
            wrapper.addSubview(chk)
            yCursor -= 6

            // Secret (masked) key field — one logical line, wraps only when very long
            let secret = NSSecureTextField(frame: NSRect(x: inset, y: yCursor - 44, width: innerW, height: 44))
            secret.isEditable = true
            secret.isSelectable = true
            secret.isEnabled = true
            secret.focusRingType = .exterior
            secret.placeholderString = "Key"
            secret.cell?.wraps = true
            secret.cell?.lineBreakMode = .byWordWrapping
            secret.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            if let k = KeyStore.readKey(prefix: p.keyPrefix), !k.isEmpty { secret.stringValue = k }
            if firstKeyField == nil { firstKeyField = secret }
            secretFields[p.name] = secret

            // Plain (visible) key field, mirrors the secure one when the eye is toggled
            let plain = NSTextField(frame: secret.frame)
            plain.isHidden = true
            plain.isEditable = true
            plain.isSelectable = true
            plain.isEnabled = true
            plain.focusRingType = .exterior
            plain.placeholderString = "Key"
            plain.cell?.wraps = true
            plain.cell?.lineBreakMode = .byWordWrapping
            plain.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            plainFields[p.name] = plain

            wrapper.addSubview(plain)
            wrapper.addSubview(secret)
            keyFields[p.name] = secret
            yCursor -= 44

            // Button row + inline result
            yCursor -= 10
            let btnH: CGFloat = 24
            let btnY = yCursor - btnH
            let buttonOffset: CGFloat = 8

            let pasteBtn = NSButton(title: "Paste", target: self, action: #selector(pastePressed(_:)))
            pasteBtn.toolTip = "Paste key from clipboard"
            pasteBtn.frame = NSRect(x: inset, y: btnY, width: 82, height: btnH)
            pasteButtons[p.name] = pasteBtn
            wrapper.addSubview(pasteBtn)

            let eye = NSButton(title: "👁", target: self, action: #selector(toggleEcho(_:)))
            eye.toolTip = "Show / hide key"
            eye.frame = NSRect(x: inset + 88, y: btnY, width: 34, height: btnH)
            eyeToggles[p.name] = eye
            wrapper.addSubview(eye)

            let checkBtn = NSButton(title: "Check", target: self, action: #selector(checkPressed(_:)))
            checkBtn.frame = NSRect(x: inset + 128, y: btnY, width: 74, height: btnH)
            checkButtons[p.name] = checkBtn
            wrapper.addSubview(checkBtn)

            let res = NSTextField(labelWithString: "")
            res.lineBreakMode = .byTruncatingTail
            res.textColor = .secondaryLabelColor
            res.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            res.alignment = .right
            res.frame = NSRect(x: inset + buttonOffset + 200, y: btnY, width: innerW - 200 - buttonOffset, height: btnH)
            resultLabels[p.name] = res
            wrapper.addSubview(res)

            yCursor = btnY
        }
        return wrapper
    }

    private func buildAutostartView() -> NSView {
        let chk = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(autostartToggled(_:)))
        chk.state = FileManager.default.fileExists(atPath: autostartPlist) ? .on : .off
        autostartCheck = chk

        let note = NSTextField(wrappingLabelWithString: "When enabled, creates a LaunchAgent \\(agentId) that opens the app at system login. No relaunch needed afterwards.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [chk, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 300))
        stack.frame = NSRect(x: 20, y: 20, width: 540, height: 200)
        wrapper.addSubview(stack)
        return wrapper
    }

    private func updateAutostartState() {
        autostartCheck?.state = FileManager.default.fileExists(atPath: autostartPlist) ? .on : .off
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func enabledToggled(_ sender: NSButton) {
        guard let name = enabledChecks.first(where: { $0.value === sender })?.key,
              let p = providers.first(where: { $0.name == name }) else { return }
        p.enabled = (sender.state == .on)
        KeyStore.writeEnabled(prefix: p.keyPrefix, on: p.enabled)
    }

    @objc private func checkPressed(_ sender: NSButton) {
        guard let name = checkButtons.first(where: { $0.value === sender })?.key,
              let p = providers.first(where: { $0.name == name }) else { return }
        let key = keyFields[name]?.stringValue ?? ""
        let label = resultLabels[name]
        guard !key.isEmpty else { label?.stringValue = "Enter a key first"; return }
        label?.stringValue = "Checking…"
        p.fetchBalance(apiKey: key) { rem, usage, limit, err in
            guard let label = label else { return }
            if let err = err {
                label.stringValue = "Error: \(err)"
            } else {
                var s = "Balance: \(fmtMoney(rem))"
                if let u = usage { s += "   Usage (all-time): \(fmtMoney(u))" }
                label.stringValue = s
            }
        }
    }

    @objc private func pastePressed(_ sender: NSButton) {
        guard let name = pasteButtons.first(where: { $0.value === sender })?.key,
              let secret = secretFields[name], let plain = plainFields[name] else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else {
            resultLabels[name]?.stringValue = "Clipboard is empty"
            return
        }
        let active: NSTextField = secret.isHidden ? plain : secret
        active.stringValue = text
        resultLabels[name]?.stringValue = "Pasted from clipboard"
    }

    @objc private func toggleEcho(_ sender: NSButton) {
        guard let name = eyeToggles.first(where: { $0.value === sender })?.key,
              let secret = secretFields[name], let plain = plainFields[name] else { return }
        if secret.isHidden {
            secret.stringValue = plain.stringValue
            secret.isHidden = false
            plain.isHidden = true
            keyFields[name] = secret
        } else {
            plain.stringValue = secret.stringValue
            secret.isHidden = true
            plain.isHidden = false
            keyFields[name] = plain
        }
    }

    @objc private func applyPressed() {
        for p in providers {
            if let f = keyFields[p.name] {
                KeyStore.writeKey(prefix: p.keyPrefix, value: f.stringValue)
            }
        }
        window?.close()
        onApply?()
    }

    @objc private func autostartToggled(_ sender: NSButton) {
        let uid = getuid()
        let on = (sender.state == .on)
        if on {
            writeAutostartPlist()
            runLaunchctl(["bootout", "gui/\(uid)/\(agentId)"])
            runLaunchctl(["bootstrap", "gui/\(uid)", autostartPlist])
        } else {
            runLaunchctl(["bootout", "gui/\(uid)/\(agentId)"])
            try? FileManager.default.removeItem(atPath: autostartPlist)
        }
        updateAutostartState()
    }

    private func writeAutostartPlist() {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try? FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistURL = launchAgents.appendingPathComponent(agentId + ".plist")
        let agent: [String: Any] = [
            "Label": agentId,
            "ProgramArguments": ["/usr/bin/open", appPath],
            "RunAtLoad": true
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
        }
    }

    private func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let providers: [Provider] = [OpenRouterProvider(), DeepSeekProvider()]
    private var balances: [String: ProviderBalance] = [:]
    private var settingsController: SettingsWindowController!

    private static let refreshInterval: TimeInterval = 60.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settingsController = SettingsWindowController(providers: providers)
        settingsController.onApply = { [weak self] in self?.refresh() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◐ $--"
        statusItem.menu = menu
        // Load persisted enabled-flags BEFORE the first refresh, so a provider
        // the user left enabled shows its balance immediately at launch — no
        // need to reopen Settings and hit Apply. (Enabled flags are only read
        // in buildProvidersView otherwise, which runs after launch.)
        for p in providers { p.enabled = KeyStore.readEnabled(prefix: p.keyPrefix) }
        buildMenu()
        refresh()

        let timer = Timer(timeInterval: AppDelegate.refreshInterval, target: self, selector: #selector(refreshTimerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func refreshTimerFired() { refresh() }

    @objc func refreshNow() { refresh() }

    @objc func openOpenRouter() {
        if let url = URL(string: "https://openrouter.ai") { NSWorkspace.shared.open(url) }
    }

    @objc func openSupport() {
        let addr = "0x6f1D0161aae17EB7Bf7cEC7e30BeE775CB149a08"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(addr, forType: .string)
        let n = NSUserNotification()
        n.title = "Support the project"
        n.informativeText = "USDT (BEP20) address copied to clipboard"
        NSUserNotificationCenter.default.deliver(n)
    }

    @objc func openSettings() { settingsController.showWindow() }

    @objc func quit() { NSApp.terminate(nil) }

    private func buildMenu() {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "LLM Balance", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        for p in providers {
            let hasKey = KeyStore.readKey(prefix: p.keyPrefix) != nil
            if !hasKey {
                let item = NSMenuItem(title: "\(p.name): no key set", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                continue
            }
            let item = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if let e = providerErrors[p.name] {
                let ei = NSMenuItem(title: "Balance: check failed", action: nil, keyEquivalent: "")
                ei.isEnabled = false
                ei.toolTip = e
                menu.addItem(ei)
            } else if let b = balances[p.name], let r = b.remaining {
                let ri = NSMenuItem(title: "Balance: \(fmtMoney(r))", action: nil, keyEquivalent: ""); ri.isEnabled = false; menu.addItem(ri)
                if let u = b.usage {
                    let ui = NSMenuItem(title: "Usage (all-time): \(fmtMoney(u))", action: nil, keyEquivalent: ""); ui.isEnabled = false; menu.addItem(ui)
                }
            } else {
                let ni = NSMenuItem(title: "Balance: n/a", action: nil, keyEquivalent: ""); ni.isEnabled = false; menu.addItem(ni)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open OpenRouter", action: #selector(openOpenRouter), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Support the project…", action: #selector(openSupport), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    private var sumRemaining: Double {
        return balances.values.compactMap { $0.remaining }.reduce(0, +)
    }
    private var anyData: Bool {
        return balances.values.contains { $0.remaining != nil }
    }

    private func worstDot() -> String {
        let ratios = balances.values.compactMap { $0.ratio }
        guard let w = ratios.min() else { return "🟢" }
        if w > 0.5 { return "🟢" }
        if w > 0.2 { return "🟡" }
        return "🔴"
    }

    private func updateUI() {
        if anyData {
            statusItem.button?.title = "\(worstDot()) \(fmtMoney(sumRemaining))"
        } else {
            statusItem.button?.title = "◐ $--"
        }
        buildMenu()
    }

    private var providerErrors: [String: String] = [:]

    func refresh() {
        var pending = 0
        for p in providers {
            let hasKey = KeyStore.readKey(prefix: p.keyPrefix) != nil
            if !p.enabled || !hasKey {
                balances.removeValue(forKey: p.name)
                providerErrors.removeValue(forKey: p.name)
                continue
            }
            guard let key = KeyStore.readKey(prefix: p.keyPrefix) else { continue }
            pending += 1
            p.fetchBalance(apiKey: key) { [weak self] remaining, usage, limit, err in
                guard let self = self else { return }
                if let e = err {
                    self.balances.removeValue(forKey: p.name)
                    self.providerErrors[p.name] = e
                } else {
                    self.balances[p.name] = ProviderBalance(remaining: remaining, usage: usage, limit: limit)
                    self.providerErrors.removeValue(forKey: p.name)
                }
                pending -= 1
                if pending == 0 { self.updateUI() }
            }
        }
        if pending == 0 { updateUI() }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
