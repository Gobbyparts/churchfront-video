import Foundation

// NewTek/Vizrt TriCaster control over its HTTP API on port 5952, which needs no login.
// Commands are /v1/shortcut?name=…&value=…; state is read from /v1/dictionary, and a
// WebSocket at /v1/change_notifications says which dictionary changed.
//
// The state is laid out as ATEMState so the app's views work unchanged: M/E 1 is Main,
// M/E 2 to 5 are the TriCaster's M/E 1 to 4, Main's overlays are the DSKs and each M/E's
// overlays are its keys. Source ids sit in the ranges ATEMInput already understands.

/// Source ids for TriCaster sources: inputs keep their numbers, Black is 0, buffers,
/// DDRs and GFX sit with the media players, Main program and preview are 10010 and
/// 10011, and the M/Es are 10020 to 10050 (as M/E 2 to 5 program on an ATEM).
public enum TriCasterSource {
    public static func id(_ name: String) -> Int? {
        let n = name.lowercased()
        func number(after p: String) -> Int? { n.hasPrefix(p) ? Int(n.dropFirst(p.count)) : nil }
        switch n {
        case "black": return 0
        case "program": return 10010
        case "preview": return 10011
        default: break
        }
        if let i = number(after: "input"), (1...99).contains(i) { return i }
        if let i = number(after: "bfr"), (1...49).contains(i) { return 3000 + i * 10 }
        if let i = number(after: "ddr"), (1...9).contains(i) { return 3500 + i * 10 }
        if let i = number(after: "gfx"), (1...9).contains(i) { return 3600 + i * 10 }
        if let i = number(after: "v"), (1...8).contains(i) { return 10010 + i * 10 }
        return nil
    }

    /// The name a shortcut takes for a source, such as INPUT2, BFR1 or V1.
    public static func name(_ id: Int) -> String? {
        switch id {
        case 0: return "Black"
        case 1...99: return "INPUT\(id)"
        case 3010...3490 where id % 10 == 0: return "BFR\((id - 3000) / 10)"
        case 3510...3590 where id % 10 == 0: return "DDR\((id - 3500) / 10)"
        case 3610...3690 where id % 10 == 0: return "GFX\((id - 3600) / 10)"
        case 10010: return "Program"
        case 10011: return "Preview"
        case 10020...10090 where id % 10 == 0: return "V\((id - 10010) / 10)"
        default: return nil
        }
    }
}

/// Reads a TriCaster's dictionaries into an ATEMState. Kept apart from the network code so
/// tests can feed it captured XML.
public struct TriCasterDictionaries {
    public struct Macro: Equatable { public let id: String; public let name: String }

    public var switcher: XMLDocument?
    public var tally: XMLDocument?
    public var states: [String: String] = [:]
    public var macros: [Macro] = []
    public var product = ""
    public var version = ""
    public var frameRate = 29.97

    public init() {}

    public static func states(_ data: Data) -> [String: String] {
        guard let doc = try? XMLDocument(data: data) else { return [:] }
        var out: [String: String] = [:]
        for e in elements(doc, "//shortcut_state") {
            if let n = attr(e, "name") { out[n] = attr(e, "value") ?? "" }
        }
        return out
    }

    /// Macros people recorded, in the order the TriCaster lists them. The read-only system
    /// folder (hundreds of built-in commands) is left out.
    public static func macros(_ data: Data) -> [Macro] {
        guard let doc = try? XMLDocument(data: data) else { return [] }
        return elements(doc, "//macro").compactMap { m in
            var p = m.parent as? XMLElement
            while let f = p {
                if f.name == "systemfolder" || attr(f, "isreadonly") == "true" { return nil }
                p = f.parent as? XMLElement
            }
            guard let id = attr(m, "identifier"), let name = attr(m, "name") else { return nil }
            return Macro(id: id, name: name)
        }
    }

    static func attr(_ e: XMLElement?, _ n: String) -> String? { e?.attribute(forName: n)?.stringValue }
    static func elements(_ node: XMLNode?, _ xpath: String) -> [XMLElement] {
        ((try? node?.nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement }
    }

    /// Names of up to 8 characters stay as they are; longer ones are cut for the panel buttons.
    static func short(_ long: String) -> String {
        long.count <= 8 ? long : String(long.prefix(8)).trimmingCharacters(in: .whitespaces)
    }

    /// "main" for Main (M/E 1 here), "v1" for the TriCaster's M/E 1 (M/E 2 here) and so on.
    public static func prefix(_ me: Int) -> String { me == 0 ? "main" : "v\(me)" }

    public var state: ATEMState {
        typealias D = TriCasterDictionaries
        var s = ATEMState()
        s.product = product
        s.version = version
        let root = switcher?.rootElement()

        // The M/Es name their sources by tally column number.
        var byIndex: [Int: String] = [:]
        for c in D.elements(tally, "//column") {
            if let n = D.attr(c, "name"), let i = D.attr(c, "index").flatMap(Int.init) { byIndex[i] = n }
        }
        func source(_ v: String?) -> Int? {
            guard let v, !v.isEmpty else { return nil }
            if let i = Int(v) { return i < 0 ? nil : byIndex[i].flatMap(TriCasterSource.id) }
            return TriCasterSource.id(v)
        }

        s.inputs[0] = ATEMInput(id: 0, long: "Black", short: "Black")
        s.inputs[10010] = ATEMInput(id: 10010, long: "Program", short: "PGM")
        s.inputs[10011] = ATEMInput(id: 10011, long: "Preview", short: "PVW")
        for p in D.elements(root, "inputs/physical_input") {
            guard let n = D.attr(p, "physical_input_number"), let id = TriCasterSource.id(n) else { continue }
            let long = D.attr(p, "iso_label").flatMap { $0.isEmpty ? nil : $0 } ?? n
            s.inputs[id] = ATEMInput(id: id, long: long, short: id < 100 ? D.short(long) : (D.attr(p, "button_label") ?? long))
        }

        func tbar(_ e: XMLElement?) -> (position: Double, seconds: Double?) {
            let t = D.elements(e, "tbar").first
            return (D.attr(t, "position").flatMap(Double.init) ?? 0, D.attr(t, "current_speed").flatMap(Double.init))
        }
        func delegate(_ me: Int) -> Set<String> {
            Set((states["\(D.prefix(me))_delegate"] ?? "").split(separator: "|").map { String($0).lowercased() })
        }
        func nextMask(_ me: Int, keys: Bool) -> Int {
            let d = delegate(me), p = D.prefix(me)
            var mask = d.isEmpty || d.contains("\(p)_background") ? 1 : 0
            if keys { for k in 1...4 where d.contains("\(p)_dsk\(k)") { mask |= 1 << k } }
            return mask
        }
        func transition(_ me: Int, _ e: XMLElement?) {
            let t = tbar(e)
            s.position[me] = t.position
            s.inTransition[me] = t.position > 0 && t.position < 1
            if let sec = t.seconds { s.mixRate[me] = max(1, Int((sec * frameRate).rounded())) }
            let fade = states["\(D.prefix(me))_background_select_fade"]
            s.style[me] = fade == "false" ? 2 : 0
        }

        // Main: program, preview, T-bar and its overlays as DSKs.
        if let root {
            s.program[0] = source(D.attr(root, "main_source")) ?? 0
            s.preview[0] = source(D.attr(root, "preview_source")) ?? 0
            transition(0, root)
            s.nextSelection[0] = nextMask(0, keys: false)
            let ties = delegate(0)
            let overlays = D.elements(root, "switcher_overlays/overlay")
            // Main has as many DSKs as it has DSK source settings; before those are read,
            // count the overlays that have a source.
            let fromStates = (1...4).filter { states["main_dsk\($0)_select_named_input"] != nil }.count
            let count = fromStates > 0 ? fromStates : overlays.filter { !(D.attr($0, "source") ?? "").isEmpty }.count
            for (i, o) in overlays.prefix(count).enumerated() {
                let pos = tbar(o).position
                s.dskOnAir[i] = pos > 0
                s.dskInTransition[i] = pos > 0 && pos < 1
                s.dskTie[i] = ties.contains("main_dsk\(i + 1)")
                if let src = source(D.attr(o, "source")) { s.dskFill[i] = src; s.dskCut[i] = src }
            }
            // TriCaster has no fade-to-black state in its dictionaries; Main's FTB is shown off.
            s.ftbBlack[0] = false
        }

        // The TriCaster's M/Es: programs, previews and keys.
        for v in D.elements(root, "inputs/simulated_input") {
            guard let n = D.attr(v, "simulated_input_number"), let id = TriCasterSource.id(n) else { continue }
            switch id {
            case 3510...3690:
                s.inputs[id] = ATEMInput(id: id, long: n.replacingOccurrences(of: "DDR", with: "DDR ").replacingOccurrences(of: "GFX", with: "GFX "),
                                         short: n)
            case 10020...10090:
                let me = (id - 10010) / 10
                var input = ATEMInput(id: id, long: "M/E \(me)", short: "M/E \(me)")
                input.bus = true
                s.inputs[id] = input
                // An M/E with nothing picked reports -1, which the TriCaster shows as Black.
                s.program[me] = source(D.attr(D.elements(v, "source_a").first, "a")) ?? 0
                s.preview[me] = source(D.attr(D.elements(v, "source_b").first, "b")) ?? 0
                transition(me, v)
                s.nextSelection[me] = nextMask(me, keys: true)
                for (k, o) in D.elements(v, "overlay").enumerated() where !(D.attr(o, "source") ?? "").isEmpty {
                    s.keyOnAir[me, default: [:]][k] = tbar(o).position > 0
                    if let src = source(D.attr(o, "source")) {
                        s.keyFill[me, default: [:]][k] = src
                        s.keyCut[me, default: [:]][k] = src
                    }
                }
            default: break
            }
        }

        // Mix outputs act as aux outputs.
        for a in 1...8 {
            if let v = states["mix\(a)_output_source"] { s.aux[a - 1] = source(v) ?? 0 }
        }
        for (i, m) in macros.enumerated() { s.macros[i] = m.name }
        if let v = states["streaming_toggle"] { s.hasStreaming = true; s.streamStatus = Self.isOn(v) ? 4 : 0 }
        if let v = states["record_toggle"] { s.hasRecording = true; s.recordStatus = Self.isOn(v) ? 1 : 0 }

        for c in D.elements(tally, "//column") {
            guard let n = D.attr(c, "name"), let id = TriCasterSource.id(n), id < 10000 else { continue }
            let bits: UInt8 = (D.attr(c, "on_pgm") == "true" ? 1 : 0) | (D.attr(c, "on_prev") == "true" ? 2 : 0)
            if bits != 0 { s.tally[id] = bits }
        }
        return s
    }

    static func isOn(_ v: String) -> Bool { v == "1" || v.lowercased() == "true" }
}

/// One connection to a TriCaster. ATEMClient creates it when the switcher address answers
/// on the TriCaster's API port, and passes its commands here.
final class TriCasterLink {
    let host: String
    let port: UInt16
    var onState: (ATEMState) -> Void = { _ in }
    var onLink: (ATEMLink) -> Void = { _ in }
    var onLog: (ATEMLogEntry) -> Void = { _ in }

    private let queue = DispatchQueue(label: "cuevideo.tricaster")
    private let session: URLSession
    private var d = TriCasterDictionaries()
    private var current = ATEMState()
    private var running = false
    private var online = false
    private var timer: DispatchSourceTimer?
    private var socket: URLSessionWebSocketTask?
    private var socketUp = false
    private var lastSocketTry = -10.0
    private var failures = 0
    private var inFlight: Set<String> = []
    private var dirty: Set<String> = []
    private var lastFetch: [String: Double] = [:]

    private static let dictionaries = ["switcher", "tally", "shortcut_states", "macros_list"]
    private let trace = ProcessInfo.processInfo.environment["CUEVIDEO_TCTRACE"] != nil
    private func log(_ s: String) {
        guard trace else { return }
        print(String(format: "TC %.3f %@", now(), s)); fflush(stdout)
    }

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
    }

    /// Whether a TriCaster answers at this address, and its product information.
    static func probe(_ host: String, port: UInt16, done: @escaping ((product: String, version: String, frameRate: Double)?) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/v1/version") else { return done(nil) }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        URLSession(configuration: c).dataTask(with: url) { data, _, _ in
            guard let data, let doc = try? XMLDocument(data: data), doc.rootElement()?.name == "product_information" else { return done(nil) }
            func text(_ n: String) -> String { ((try? doc.nodes(forXPath: "//\(n)"))?.first?.stringValue) ?? "" }
            let name = text("product_name"), model = text("product_model")
            done(((name.isEmpty ? "TriCaster" : name) + (model.isEmpty ? "" : " (\(model))"), text("product_version"),
                  Double(text("session_frame_rate")) ?? 29.97))
        }.resume()
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func start(product: String, version: String, frameRate: Double) {
        queue.async {
            self.running = true
            self.d.product = product
            self.d.version = version
            self.d.frameRate = frameRate
            self.onLink(.connecting)
            for k in Self.dictionaries { self.refresh(k) }
            self.openSocket()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.timer?.cancel(); self.timer = nil
            self.socket?.cancel(with: .goingAway, reason: nil); self.socket = nil
            self.session.invalidateAndCancel()
        }
    }

    // MARK: State

    /// With the WebSocket up, polling is only a backstop; without it, the switcher and tally
    /// are polled four times a second.
    private func tick() {
        guard running else { return }
        let t = now()
        let every: [String: Double] = socketUp
            ? ["switcher": 2, "tally": 2, "shortcut_states": 5, "macros_list": 30]
            : ["switcher": 0.25, "tally": 0.25, "shortcut_states": 1, "macros_list": 30]
        for (k, s) in every where t - (lastFetch[k] ?? 0) >= s { refresh(k) }
        if !socketUp && t - lastSocketTry > 3 { openSocket() }
    }

    private func refresh(_ key: String) {
        guard running else { return }
        if inFlight.contains(key) { dirty.insert(key); return }
        inFlight.insert(key)
        lastFetch[key] = now()
        log("fetch \(key)")
        get("dictionary?key=\(key)") { data in
            self.inFlight.remove(key)
            self.log("got \(key) \(data?.count ?? -1) bytes")
            guard self.running else { return }
            guard let data else { self.failed(); return }
            self.failures = 0
            switch key {
            case "switcher": self.d.switcher = try? XMLDocument(data: data)
            case "tally": self.d.tally = try? XMLDocument(data: data)
            case "shortcut_states": self.d.states = TriCasterDictionaries.states(data)
            case "macros_list": self.d.macros = TriCasterDictionaries.macros(data)
            default: break
            }
            self.publish()
            if self.dirty.remove(key) != nil { self.refresh(key) }
        }
    }

    private func failed() {
        failures += 1
        if failures >= 3 && online {
            online = false
            onLink(.offline("No answer from \(host)"))
        }
    }

    private func publish() {
        guard d.switcher != nil, d.tally != nil else { return }
        if !online { online = true; onLink(.online) }
        let s = d.state
        if s != current {
            log("state: program \(s.program[0] ?? -1) preview \(s.preview[0] ?? -1) position \(s.position[0] ?? -1)")
            current = s; onState(s)
        }
    }

    private func get(_ path: String, _ done: @escaping (Data?) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/v1/\(path)") else { return done(nil) }
        session.dataTask(with: url) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            self.queue.async { done(ok ? data : nil) }
        }.resume()
    }

    private func openSocket() {
        lastSocketTry = now()
        socket?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "ws://\(host):\(port)/v1/change_notifications") else { return }
        let ws = session.webSocketTask(with: url)
        socket = ws
        ws.resume()
        receive(ws)
    }

    /// Each message names a dictionary that changed, such as "tally" (with a trailing NUL).
    private func receive(_ ws: URLSessionWebSocketTask) {
        ws.receive { result in
            self.queue.async {
                guard ws === self.socket, self.running else { return }
                switch result {
                case .success(let m):
                    self.socketUp = true
                    let text: String
                    switch m {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: text = ""
                    }
                    let key = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
                    self.log("notified \(key)")
                    if Self.dictionaries.contains(key) { self.refresh(key) }
                    self.receive(ws)
                case .failure:
                    self.socketUp = false
                    self.socket = nil
                }
            }
        }
    }

    // MARK: Commands

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))

    /// Sends one shortcut and logs it for the Status page, then rereads the switcher and
    /// tally so the change shows without waiting for the notification.
    private func shortcut(_ name: String, _ value: String? = nil, _ what: String) {
        queue.async {
            var q = "name=" + (name.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? name)
            if let value { q += "&value=" + (value.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? value) }
            let ok = self.running && self.online
            self.onLog(ATEMLogEntry(time: Date(), command: "\(what) [\(name)\(value.map { "=\($0)" } ?? "")]", data: [], sent: ok))
            guard ok else { return }
            self.get("shortcut?\(q)") { _ in
                self.refresh("switcher")
                self.refresh("tally")
            }
        }
    }

    /// Runs a command that needs the latest state, on the link's queue.
    private func withState(_ f: @escaping (ATEMState) -> Void) { queue.async { f(self.current) } }

    private func meName(_ me: Int) -> String { me == 0 ? "Main" : "M/E \(me)" }
    private func p(_ me: Int) -> String { TriCasterDictionaries.prefix(me) }
    private func label(_ id: Int) -> String { current.inputs[id]?.long ?? TriCasterSource.name(id) ?? "source \(id)" }

    func setProgram(_ source: Int, me: Int) {
        guard let n = TriCasterSource.name(source) else { return }
        withState { _ in self.shortcut("\(self.p(me))_a_row_named_input", n, "Program, \(self.meName(me)): \(self.label(source))") }
    }
    func setPreview(_ source: Int, me: Int) {
        guard let n = TriCasterSource.name(source) else { return }
        withState { _ in self.shortcut("\(self.p(me))_b_row_named_input", n, "Preview, \(self.meName(me)): \(self.label(source))") }
    }
    func cut(me: Int) { shortcut("\(p(me))_take", nil, "Cut, \(meName(me))") }
    func auto(me: Int) { shortcut("\(p(me))_auto", nil, "Auto transition, \(meName(me))") }
    func setPosition(_ v: Double, me: Int) {
        let x = min(1, max(0, v))
        // The TriCaster's T-bar takes 0 to 100.
        shortcut("\(p(me))_value", String(format: "%.1f", x * 100), "T-bar, \(meName(me)): \(Int(x * 100))%")
    }
    /// The TriCaster's API has no working shortcut for transition speed, and picking Fade
    /// over it resets the speed to Medium, so neither is changed from here. The TriCaster's
    /// own speed still shows.
    func setStyle(_ style: Int, me: Int) { unsupported("Transition style", me) }
    /// Background plus keys (bit 1 = key 1). On Main the keys are DSKs, set with setDSKTie.
    func setNextSelection(_ mask: Int, me: Int) {
        withState { s in
            let keys = me == 0 ? Set((0..<4).filter { s.dskTie[$0] == true }.map { $0 + 1 }) : Set((1...4).filter { mask >> $0 & 1 == 1 })
            self.setDelegate(me, background: mask & 1 == 1, keys: keys)
        }
    }
    func setDSKTie(_ dsk: Int, _ on: Bool) {
        withState { s in
            var keys = Set((0..<4).filter { s.dskTie[$0] == true }.map { $0 + 1 })
            if on { keys.insert(dsk + 1) } else { keys.remove(dsk + 1) }
            self.setDelegate(0, background: (s.nextSelection[0] ?? 1) & 1 == 1, keys: keys)
        }
    }
    private func setDelegate(_ me: Int, background: Bool, keys: Set<Int>) {
        var parts = background ? ["\(p(me))_background"] : []
        parts += keys.sorted().map { "\(p(me))_dsk\($0)" }
        if parts.isEmpty { parts = ["\(p(me))_background"] }
        shortcut("\(p(me))_delegate", parts.joined(separator: "|"), "Next transition, \(meName(me)): \(parts.joined(separator: ", "))")
    }
    func setMixRate(_ frames: Int, me: Int) { unsupported("Transition speed", me) }
    private func unsupported(_ what: String, _ me: Int) {
        queue.async { self.onLog(ATEMLogEntry(time: Date(), command: "\(what), \(self.meName(me)): set it on the TriCaster", data: [], sent: false)) }
    }
    /// Keys on the TriCaster's M/Es; Main has none of its own (its overlays are DSKs).
    func setKeyOnAir(_ keyer: Int, _ on: Bool, me: Int) {
        guard me > 0 else { return setDSKOnAir(keyer, on) }
        withState { s in
            guard (s.keyOnAir[me]?[keyer] ?? false) != on else { return }
            self.shortcut("\(self.p(me))_dsk\(keyer + 1)_take", nil, "Key \(keyer + 1) \(on ? "on" : "off"), \(self.meName(me))")
        }
    }
    func setDSKOnAir(_ dsk: Int, _ on: Bool) {
        withState { s in
            guard (s.dskOnAir[dsk] ?? false) != on else { return }
            self.shortcut("main_dsk\(dsk + 1)_take", nil, "DSK \(dsk + 1) \(on ? "on" : "off")")
        }
    }
    func dskAuto(_ dsk: Int) { shortcut("main_dsk\(dsk + 1)_auto", nil, "DSK \(dsk + 1) auto") }
    func fadeToBlack(me: Int) { shortcut("\(p(me))_ftb_auto", nil, "Fade to black, \(meName(me))") }
    func setAux(_ aux: Int, _ source: Int) {
        guard let n = TriCasterSource.name(source) else { return }
        withState { _ in self.shortcut("mix\(aux + 1)_output_source", n, "Mix \(aux + 1) output: \(self.label(source))") }
    }
    func runMacro(_ index: Int) {
        withState { _ in
            guard index >= 0, index < self.d.macros.count else { return }
            let m = self.d.macros[index]
            self.shortcut("play_macro_byid", m.id, "Run macro \(m.name)")
        }
    }
    func stopMacro() { shortcut("stop_all_macros", nil, "Stop macros") }
    func setStreaming(_ on: Bool) {
        withState { s in
            guard s.streaming != on else { return }
            self.shortcut("streaming_toggle", nil, "Streaming \(on ? "start" : "stop")")
        }
    }
    func setRecording(_ on: Bool) {
        withState { s in
            guard s.recording != on else { return }
            self.shortcut("record_toggle", nil, "Recording \(on ? "start" : "stop")")
        }
    }
}
