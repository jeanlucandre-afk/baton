import AppKit
import BatonCore
import Foundation

let usage = """
baton-probe — tests Baton's detection engine on real windows

  baton-probe list                      list windows and how much text Accessibility exposes
  baton-probe peek <n> [<n>...]         show what a window exposes (buttons, last text)
  baton-probe watch <n> [<n>...]        watch windows by number from `list`
        --settle <seconds>              stillness before asking Jev (default 2.5)
        --dry                           read windows but never call Jev
  baton-probe summary-test              try Apple's on-device model on a sample
  baton-probe sidebar <n> [<n>...]      chats a window's sidebar lists, with their status
  baton-probe capture <n> <file.json>   save a window's tree (long text removed) as a test fixture
  baton-probe relearn <n> [--break] [--gemini] [--save]
                                        re-learn how to read a window's sidebar; --break starts from a
                                        broken profile (a simulated app update), --gemini skips the
                                        on-Mac list search, --save keeps the result
  baton-probe profiles                  where saved profiles live, and which apps they cover

Logs go to ~/Developer/Baton/logs/.
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func requireAccessibility() {
    guard AX.isTrusted(prompt: true) else {
        print("Baton needs Accessibility access: System Settings › Privacy & Security › Accessibility.")
        exit(1)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

final class Log: @unchecked Sendable {
    private let handle: FileHandle?
    let path: String

    init(dir: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        path = "\(dir)/probe-\(f.string(from: Date())).jsonl"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ obj: [String: Any]) {
        var o = obj
        o["ts"] = ISO8601DateFormatter().string(from: Date())
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        handle?.write(d + Data("\n".utf8))
    }
}

switch command {
case "list":
    requireAccessibility()
    for (i, w) in AX.listWindows().enumerated() {
        let s = AX.snapshot(w)
        let info = s.map { "\($0.tail.count) chars · \($0.buttons.count) buttons · \(Int($0.millis)) ms" } ?? "unreadable"
        let name = "\(w.appName) · \(w.title.isEmpty ? "(untitled)" : String(w.title.prefix(50)))"
        print(String(format: "%3d  ", i) + name.padding(toLength: 64, withPad: " ", startingAt: 0) + info)
    }

case "peek":
    requireAccessibility()
    let all = AX.listWindows()
    for n in args.compactMap(Int.init) {
        guard let w = all[safe: n] else { continue }
        AX.enableTree(pid: w.pid)
        guard let s = AX.snapshot(w) else { continue }
        print("=== \(n) \(w.appName) · \(s.title) · \(s.nodes) nodes · \(Int(s.millis)) ms")
        print("buttons: \(s.buttons.joined(separator: " | "))")
        print("--- last 600 chars ---\n\(String(s.tail.suffix(600)))\n")
    }

case "sidebar":
    requireAccessibility()
    let all = AX.listWindows()
    for n in args.compactMap(Int.init) {
        guard let w = all[safe: n] else { continue }
        AX.enableTree(pid: w.pid)
        let start = Date()
        let rows = Sidebar.rows(in: w)
        print("=== \(w.appName) · \(rows.count) chats with a status · \(Int(Date().timeIntervalSince(start) * 1000)) ms · open: \(Sidebar.openChat(in: w)) · tabs: \(Sidebar.sections(in: w).map { "\($0.name)\($0.selected ? "*" : "")\($0.activity.map { " (" + $0 + ")" } ?? "")" })")
        for r in rows { print("  \(r.status.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(r.name)") }
    }

case "composer":
    // Read-only: what "Continue in new chat" would use in a window (message box, Send, context, new-chat button).
    requireAccessibility()
    guard let n = args.first.flatMap(Int.init), let w = AX.listWindows()[safe: n] else { print("composer <n>"); exit(1) }
    AX.enableTree(pid: w.pid)
    guard let root = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 2000) else { print("couldn't read the window"); exit(1) }
    let open = Sidebar.openChat(in: root, bundleID: w.bundleID)
    let c = Composer.find(in: root)
    print("open chat:   \(open.name ?? "?")  generating: \(open.generating)")
    print("message box: \(c == nil ? "not found" : "found, text: \"\(c!.text)\"")")
    print("send:        \(c?.send == nil ? "not found" : "found")")
    print("context:     \(Composer.contextPercent(in: root).map { "\($0)%" } ?? "not shown")")
    print("new chat:    \(open.name.flatMap { Composer.newChatButton(near: $0, in: root).map { $0.desc ?? $0.title ?? "?" } } ?? "not found")")

case "usage":
    // Read-only: what the usage readers see right now (Codex log, Claude and Cursor windows).
    func show(_ name: String, _ u: AppUsage?) {
        guard let u else { print("\(name): nothing"); return }
        func f(_ l: Limit?) -> String { l.map { "\(Int($0.percent))%\($0.resetsAt.map { " resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")" } ?? "-" }
        print("\(name): 5h \(f(u.five)) · week \(f(u.week)) · plan \(f(u.plan))")
    }
    show("Codex", UsageReader.codex())
    requireAccessibility()
    for w in AX.listWindows() where ["com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92"].contains(w.bundleID) {
        AX.enableTree(pid: w.pid)
        guard let root = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 1500) else { continue }
        let labels = UsageReader.labels(in: root)
        for l in labels { print("  label: \(l)") }
        if w.bundleID.contains("anthropic") { for l in labels { show(w.appName, UsageReader.claude(label: l)) } }
        else { show(w.appName, UsageReader.cursor(labels: labels)) }
    }

case "usagebench":
    // Read-only: the Codex usage read, the old way (log's last 256 KB each time) vs from where it stopped.
    let rounds = args.first.flatMap(Int.init) ?? 20
    var t = Date()
    for _ in 0..<rounds { _ = UsageReader.codex() }
    print(String(format: "full tail read: %.1f ms per read", Date().timeIntervalSince(t) * 1000 / Double(rounds)))
    let log = CodexUsageLog()
    t = Date()
    _ = log.read()
    print(String(format: "incremental, first read: %.1f ms, %d bytes", Date().timeIntervalSince(t) * 1000, log.lastBytesRead))
    t = Date()
    var bytes = 0
    for _ in 0..<rounds { _ = log.read(); bytes += log.lastBytesRead }
    print(String(format: "incremental, later reads: %.1f ms per read, %d bytes each", Date().timeIntervalSince(t) * 1000 / Double(rounds), bytes / rounds))
    print("same answer: \(log.read() == UsageReader.codex())")

case "capture":
    requireAccessibility()
    guard let n = args.first.flatMap(Int.init), let w = AX.listWindows()[safe: n], let out = args[safe: 1] else { print("capture <n> <file.json>"); exit(1) }
    AX.enableTree(pid: w.pid)
    guard let root = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 2000) else { print("couldn't read the window"); exit(1) }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    try enc.encode(root.trimmedForFixture()).write(to: URL(fileURLWithPath: out))
    print("\(w.appName): \(root.count) elements → \(out) (\(w.bundleID))")

case "relearn":
    requireAccessibility()
    guard let n = args.first.flatMap(Int.init), let w = AX.listWindows()[safe: n] else { print("relearn <n> [--break] [--save]"); exit(1) }
    AX.enableTree(pid: w.pid)
    guard let root = AXNode.capture(w.element, maxNodes: 8000, maxMillis: 2000) else { print("couldn't read the window"); exit(1) }
    var book = Profiles.shared.current
    let working = Sidebar.rows(in: root, profile: book.profile(w.bundleID), notChats: book.notChats)
    let health = ReaderHealth.load()
    let known = health.known(w.bundleID).isEmpty ? working.map(\.name) : health.known(w.bundleID)
    let usual = max(health.apps[w.bundleID]?.usual ?? 0, working.count)
    if args.contains("--break") {
        // What an app update looks like: the chat list moved and the status labels changed.
        var broken = book.profile(w.bundleID)
        broken.list = NodeMatch(role: "AXList", desc: "Old chat list")
        broken.hidden = false
        broken.comma = false
        book.apps[w.bundleID] = broken
        print("Broken profile reads \(Sidebar.rows(in: root, profile: broken, notChats: book.notChats).count) chats (was \(working.count)).")
    }
    print("Re-learning \(w.appName) with \(known.count) known chats…")
    Task {
        let start = Date()
        guard let o = await ProfileRepair.repair(root: root, bundleID: w.bundleID, appName: w.appName, known: known, usual: usual, smart: Smart(), book: book, localSearch: !args.contains("--gemini"), log: { print($0) }) else {
            print("No profile passed the check. Nothing changed."); exit(1)
        }
        print("Repaired via \(o.via) in \(Int(Date().timeIntervalSince(start) * 1000)) ms: \(o.rows.count) chats, \(o.knownFound)/\(known.count) known found")
        for r in o.rows { print("  \(r.status.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(r.name)") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: (try? enc.encode(o.profile)) ?? Data(), as: UTF8.self))
        if args.contains("--save") {
            do { try Profiles.shared.save(o.profile, for: w.bundleID); print("Saved to \(Profiles.fileURL.path)") }
            catch { print("Couldn't save: \(error)") }
        }
        exit(0)
    }
    RunLoop.main.run()

case "profiles":
    print(Profiles.fileURL.path)
    let saved = Profiles.shared.saved
    print(saved.map { "saved (v\($0.version)): " + $0.apps.keys.sorted().joined(separator: ", ") } ?? "none saved; built-in profiles in use")

case "open":
    // open <n> <chat name>: click that chat in the window's sidebar, then report what's open
    requireAccessibility()
    guard let n = args.first.flatMap(Int.init), let w = AX.listWindows()[safe: n] else { exit(1) }
    let name = args.dropFirst().joined(separator: " ")
    AX.enableTree(pid: w.pid)
    print("before: \(Sidebar.currentChat(in: w) ?? "-")")
    let t0 = Date()
    print("opened: \(Sidebar.openVerified(name, in: w)) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    print("after: \(Sidebar.currentChat(in: w) ?? "-")")

case "rowframe":
    requireAccessibility()
    guard let n = args.first.flatMap(Int.init), let w = AX.listWindows()[safe: n] else { exit(1) }
    let name = args.dropFirst().joined(separator: " ")
    guard let el = Sidebar.rowElement(name, in: w) else { print("no row"); exit(0) }
    var pos: CFTypeRef?, size: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos)
    AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size)
    print("pos \(String(describing: pos)) size \(String(describing: size))")
    AX.raise(w)
    Thread.sleep(forTimeInterval: 0.5)
    print("front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
    if ProcessInfo.processInfo.environment["CLICK"] != nil {
        print("clicked: \(AX.click(el))")
        Thread.sleep(forTimeInterval: 1.5)
        print("open now: \(Sidebar.currentChat(in: w) ?? "-")")
    }

case "press":
    // press <n> <description>: press the first element in window n whose description or title matches
    requireAccessibility()
    guard let n = args.first.flatMap(Int.init), let w = AX.listWindows()[safe: n],
          let root = AXNode.capture(w.element, maxNodes: 4000, maxMillis: 1000) else { exit(1) }
    let target = args.dropFirst().joined(separator: " ").lowercased()
    var stack = [root]
    while let node = stack.popLast() {
        if [node.desc, node.title].compactMap({ $0?.lowercased() }).contains(where: { $0.hasPrefix(target) }), let el = node.element {
            print("pressing \(node.role) \(node.desc ?? node.title ?? ""): \(AXUIElementPerformAction(el, kAXPressAction as CFString) == .success)")
            break
        }
        stack.append(contentsOf: node.kids.reversed())
    }

case "pollbench":
    // Times what one sidebar poll does per app (read-only): window list, tree copy, parse.
    // pollbench [rounds] [bundle ...]; default bundles: the apps Baton reads for new chats.
    requireAccessibility()
    let rounds = args.first.flatMap(Int.init) ?? 3
    var bundles = Set(args.filter { Int($0) == nil })
    if bundles.isEmpty {
        bundles = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex", "com.anysphere.sand", "com.todesktop.230313mzl4w4u92"]
    }
    for round in 1...rounds {
        let t0 = Date()
        for app in NSWorkspace.shared.runningApplications {
            guard let b = app.bundleIdentifier, bundles.contains(b) else { continue }
            let tw = Date()
            let wins = AX.windows(pid: app.processIdentifier)
            let winMs = Date().timeIntervalSince(tw) * 1000
            for w in wins.prefix(2) {
                var truncated = false
                let tc = Date()
                let root = AXNode.capture(w.element, maxNodes: 6000, maxMillis: 500, prune: Sidebar.profile(b).prune, truncated: &truncated)
                let capMs = Date().timeIntervalSince(tc) * 1000
                let tp = Date()
                let read = Sidebar.read(root, bundleID: b, truncated: truncated)
                let parseMs = Date().timeIntervalSince(tp) * 1000
                print(String(format: "r%d %-34@ wins=%d (%.0f ms) nodes=%5d capture=%4.0f ms parse=%3.0f ms rows=%d%@ hidden=%@ min=%@",
                             round, b as NSString, wins.count, winMs, root?.count ?? 0, capMs, parseMs, read.rows.count,
                             (truncated ? " TRUNC" : "") as NSString, "\(app.isHidden)" as NSString, "\(AX.isMinimized(w))" as NSString))
            }
        }
        print(String(format: "round %d total %.0f ms", round, Date().timeIntervalSince(t0) * 1000))
    }

case "focusbench":
    // Times the focus timer's open-chat read and the trust check (read-only): focusbench <n> [rounds]
    requireAccessibility()
    let all = AX.listWindows()
    guard let n = args.first.flatMap(Int.init), let w = all[safe: n] else { print("focusbench <n> [rounds]"); exit(1) }
    let rounds = args.dropFirst().first.flatMap(Int.init) ?? 10
    var t = Date()
    var name: String?
    for _ in 0..<rounds { name = Sidebar.currentChat(element: w.element, bundleID: w.bundleID) }
    print("\(w.appName) currentChat=\(name ?? "-") avg \(Int(Date().timeIntervalSince(t) * 1000) / rounds) ms")
    t = Date()
    for _ in 0..<1000 { _ = AX.isTrusted(prompt: false) }
    print("AX.isTrusted avg \(Date().timeIntervalSince(t)) ms")
    t = Date()
    for _ in 0..<100 { _ = AX.focusedWindow() }
    print("AX.focusedWindow avg \(Date().timeIntervalSince(t) * 10) ms")

case "observe":
    // Counts the Accessibility notifications apps post (read-only): observe <seconds> <bundle ...>
    requireAccessibility()
    let secs = args.first.flatMap(Double.init) ?? 20
    let wanted = Set(args.dropFirst())
    final class Counter: @unchecked Sendable { var byKey: [String: Int] = [:] }
    let counter = Counter()
    let names = ["AXValueChanged", "AXUIElementDestroyed", "AXCreated", "AXTitleChanged", "AXLayoutChanged",
                 "AXSelectedChildrenChanged", "AXRowCountChanged", "AXFocusedUIElementChanged", "AXLiveRegionChanged",
                 "AXLiveRegionCreated", "AXLoadComplete", "AXElementBusyChanged", "AXExpandedChanged", "AXSelectedTextChanged",
                 "AXMenuOpened", "AXMenuClosed", "AXWindowCreated", "AXResized", "AXMoved", "AXSelectedRowsChanged"]
    var observers: [AXObserver] = []
    for app in NSWorkspace.shared.runningApplications {
        guard let b = app.bundleIdentifier, wanted.contains(b) else { continue }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, note, ctx in
            let c = Unmanaged<Counter>.fromOpaque(ctx!).takeUnretainedValue()
            c.byKey[note as String, default: 0] += 1
        }
        guard AXObserverCreate(app.processIdentifier, cb, &obs) == .success, let obs else { continue }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var ok: [String] = []
        for n in names where AXObserverAddNotification(obs, el, n as CFString, Unmanaged.passUnretained(counter).toOpaque()) == .success { ok.append(n) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers.append(obs)
        print("\(b): registered \(ok.count)/\(names.count)")
    }
    let end = Date().addingTimeInterval(secs)
    var last = Date()
    while Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if Date().timeIntervalSince(last) >= 5 {
            print(counter.byKey.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            counter.byKey = [:]
            last = Date()
        }
    }

case "tree":
    // Dumps a window's accessibility tree (roles, labels, states) to find how an app marks chats as busy or unread.
    requireAccessibility()
    let all = AX.listWindows()
    guard let n = args.first.flatMap(Int.init), let w = all[safe: n] else { print("tree <n> [filter]"); exit(1) }
    AX.enableTree(pid: w.pid)
    let filter = args.dropFirst().first?.lowercased()
    let attrs = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXHelp", "AXRoleDescription", "AXSelected", "AXIdentifier", "AXDOMClassList"] as CFArray
    var stack: [(AXUIElement, Int)] = [(w.element, 0)]
    var count = 0
    while let (el, d) = stack.popLast(), count < 6000 {
        count += 1
        var vals: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &vals) == .success, let a = vals as? [Any] else { continue }
        func str(_ i: Int) -> String {
            if let s = a[i] as? String { return s }
            if let b = a[i] as? Bool { return b ? "true" : "" }
            if let arr = a[i] as? [String] { return arr.joined(separator: ".") }
            if let n = a[i] as? NSNumber { return n.stringValue }
            return ""
        }
        let parts = [("role", str(0)), ("sub", str(1)), ("title", str(2)), ("desc", str(3)), ("val", String(str(4).prefix(60))),
                     ("help", str(5)), ("sel", str(7)), ("id", str(8)), ("class", String(str(9).prefix(80)))].filter { !$0.1.isEmpty }
        let line = String(repeating: " ", count: min(d, 30)) + parts.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        if filter == nil || line.lowercased().contains(filter!) { print(line) }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let k = kids as? [AXUIElement] {
            // Short timeouts like the app's walkers, so one hung element can't stall the dump for 6 s each.
            for c in k.reversed() { AXUIElementSetMessagingTimeout(c, AX.messagingTimeout); stack.append((c, d + 1)) }
        }
    }

case "watch":
    requireAccessibility()
    var config = DetectionEngine.Config()
    var dry = false
    var picks: [Int] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--settle": i += 1; config.settle = Double(args[safe: i] ?? "") ?? config.settle
        case "--dry": dry = true
        default: if let n = Int(args[i]) { picks.append(n) }
        }
        i += 1
    }
    let all = AX.listWindows()
    let chosen = picks.compactMap { all[safe: $0] }
    guard !chosen.isEmpty else { print("Pick windows by number. Run `baton-probe list` first."); exit(1) }

    var jev: Jev?
    if !dry {
        do { jev = try Jev() } catch { print("Couldn't read the Jev key from the Keychain (service \"jev-api-key\")."); exit(1) }
    }
    let log = Log(dir: NSString(string: "~/Developer/Baton/logs").expandingTildeInPath)
    print("Watching \(chosen.count) window(s) · settle \(config.settle)s · \(dry ? "dry run" : "Jev \(Jev.model)") · on-device summaries: \(Summarizer.onDeviceAvailability)")
    print("Log: \(log.path)\nCtrl-C to stop.\n")

    let engine = DetectionEngine(classifier: jev, config: config)
    var names: [UUID: String] = [:]
    for w in chosen {
        let id = UUID()
        names[id] = (w.appName + " · " + String(w.title.prefix(28))).padding(toLength: 40, withPad: " ", startingAt: 0)
        engine.watch(id, window: w)
    }
    let labels = names
    let time = DateFormatter()
    time.dateFormat = "HH:mm:ss"
    func say(_ id: UUID, _ msg: String) {
        print("\(time.string(from: Date()))  \(labels[id] ?? "?")  \(msg)")
        fflush(stdout)
    }

    Task {
        for await e in engine.events {
            switch e {
            case let .state(id, state, source):
                say(id, "STATE -> \(state.rawValue) (\(source))")
                log.write(["event": "flip", "app": labels[id] ?? "", "to": state.rawValue, "source": source])
            case let .answer(id, a, reason, cached, chars, axMs):
                say(id, String(format: "Jev %@ %.2f · asks you %.2f · error %.2f · %d ms · %d tok · $%.6f (%@%@)",
                               a.status.rawValue, a.confidence, a.asksYou, a.hasError, Int(a.millis), a.inputTokens, a.cost, reason, cached ? ", cached" : ""))
                log.write(["event": "jev", "app": labels[id] ?? "", "status": a.status.rawValue, "confidence": a.confidence,
                           "probabilities": a.probabilities, "asks_you": a.asksYou, "ms": a.millis, "tokens": a.inputTokens,
                           "reason": reason, "cached": cached, "chars": chars, "ax_ms": axMs])
            case let .ping(id, _, _, text, source, refined):
                say(id, "PING\(refined ? "+" : " ") \(text)   [\(source)]")
                log.write(["event": "ping", "app": labels[id] ?? "", "text": text, "source": source, "refined": refined])
            case let .note(id, msg):
                say(id, msg)
            case let .lost(id):
                say(id, "window closed or app quit")
            case let .contextChanged(id, title, _):
                say(id, "CONTEXT switched (now: \(title))")
            }
        }
    }

    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler {
        Task {
            let s = await engine.stats()
            print(String(format: "\n%d Jev calls · $%.5f total", s.calls, s.spent))
            exit(0)
        }
    }
    sig.resume()
    engine.start()
    RunLoop.main.run()

case "status-test":
    // status-test <app> <word…>: what Gemini thinks a sidebar status word means
    Task {
        guard let smart = Smart() else { print("No Gemini key in Keychain"); exit(1) }
        let app = args.first ?? "Claude"
        let word = args.dropFirst().joined(separator: " ")
        print("\(word) → \(String(describing: await smart.classifyStatus(word: word, app: app)))")
        exit(0)
    }
    RunLoop.main.run()

case "smart-test":
    Task {
        guard let smart = Smart() else { print("No Gemini key in Keychain"); exit(1) }
        let tail = "I rewrote the pricing page hero in three tones: Confident, Friendly, Playful. I also drafted FAQ answers for refunds and team plans. Want me to apply one tone to the whole page?"
        let start = Date()
        let p = await smart.progress(task: "Pricing page copy", steps: [], app: "ChatGPT", tail: tail, status: .finished)
        print("\(Int(Date().timeIntervalSince(start) * 1000)) ms")
        print(p.map { "summary: \($0.summary)\nnext: \($0.next)\nsteps:\n" + $0.steps.map { "  [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") } ?? "failed")
        exit(0)
    }
    RunLoop.main.run()

case "summary-test":
    print("On-device model: \(Summarizer.onDeviceAvailability)")
    let sample = """
    Here are three tones for your pricing hero: 1. Confident: "Ship faster. Pay less." 2. Friendly: "Pricing that grows with you."
    3. Playful: "Cheaper than your coffee habit." Want me to adapt any of these for the FAQ section?
    """
    Task {
        let r = await Summarizer.summarize(app: "ChatGPT", title: "Pricing copy", tail: sample, status: .finished, asksYou: true)
        print("\(r.text)\n[\(r.source), \(Int(r.millis)) ms]")
        exit(0)
    }
    RunLoop.main.run()

default:
    print(usage)
}
