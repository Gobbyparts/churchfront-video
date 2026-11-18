import Foundation
import Network
import Combine

// Blackmagic ATEM control over the network (UDP 9910), with no Blackmagic
// software installed. The switcher sends its whole state when we connect and
// every change after, so the state here always matches the panel.

public struct ATEMInput: Identifiable, Hashable {
    public let id: Int
    public var long: String
    public var short: String
    /// Set when the switcher says outright whether this source can go on a program or
    /// preview bus (a TriCaster's M/Es can); otherwise it follows the ATEM numbering.
    public var bus: Bool?

    /// Sources a program or preview bus can take: black, cameras and other
    /// inputs, bars, colors, media players and SuperSource.
    public var isBusSource: Bool {
        if let bus { return bus }
        return id == 0 || (1...999).contains(id) || id == 1000 || id == 2001 || id == 2002
            || ((3000..<4000).contains(id) && id % 10 == 0) || (6000..<6100).contains(id)
    }
    /// Aux outputs can also take clean feeds and M/E program and preview.
    public var isAuxSource: Bool { isBusSource || (7000..<7100).contains(id) || (10000..<11000).contains(id) }
    public var isExternal: Bool { (1...999).contains(id) }
    /// Inputs first in number order, then black, bars, colors, media players.
    var sortKey: (Int, Int) { isExternal ? (0, id) : (1, id) }
}

public struct ATEMState: Equatable {
    public var product = ""
    public var version = ""
    public var inputs: [Int: ATEMInput] = [:]
    public var program: [Int: Int] = [:]
    public var preview: [Int: Int] = [:]
    /// Transition handle, 0 to 1, while a transition is under way.
    public var position: [Int: Double] = [:]
    public var inTransition: [Int: Bool] = [:]
    /// Style of the next transition: 0 mix, 1 dip, 2 wipe, 3 DVE, 4 sting.
    public var style: [Int: Int] = [:]
    /// Next transition: bit 0 background, bit 1 key 1, bit 2 key 2 and so on.
    public var nextSelection: [Int: Int] = [:]
    public var mixRate: [Int: Int] = [:]
    public var keyOnAir: [Int: [Int: Bool]] = [:]
    /// Upstream key sources by M/E then keyer: fill and key (cut) inputs.
    public var keyFill: [Int: [Int: Int]] = [:]
    public var keyCut: [Int: [Int: Int]] = [:]
    /// Downstream key sources by DSK.
    public var dskFill: [Int: Int] = [:]
    public var dskCut: [Int: Int] = [:]
    public var dskOnAir: [Int: Bool] = [:]
    public var dskInTransition: [Int: Bool] = [:]
    public var dskTie: [Int: Bool] = [:]
    public var ftbBlack: [Int: Bool] = [:]
    public var ftbInTransition: [Int: Bool] = [:]
    public var aux: [Int: Int] = [:]
    /// Recorded macros by index (0 based).
    public var macros: [Int: String] = [:]
    public var macroRunning: Int?
    public var streamStatus = 0
    public var recordStatus = 0
    /// Only switchers with a built-in encoder or recorder report these.
    public var hasStreaming = false
    public var hasRecording = false
    /// Tally by source: bit 0 program, bit 1 preview (keys and DSKs included).
    public var tally: [Int: UInt8] = [:]

    public init() {}

    public var meCount: Int { max(1, (program.keys.max() ?? 0) + 1) }
    public var keyerCount: Int { keyOnAir[0]?.count ?? 0 }
    public var dskCount: Int { dskOnAir.count }
    public var auxCount: Int { aux.count }
    public var streaming: Bool { streamStatus & 4 != 0 }
    public var streamConnecting: Bool { streamStatus & 2 != 0 }
    public var recording: Bool { recordStatus & 1 != 0 }

    public var busSources: [ATEMInput] { inputs.values.filter(\.isBusSource).sorted { $0.sortKey < $1.sortKey } }
    public var auxSources: [ATEMInput] { inputs.values.filter(\.isAuxSource).sorted { $0.sortKey < $1.sortKey } }
    public func name(_ id: Int?) -> String { id.map { inputs[$0]?.short ?? "\($0)" } ?? "?" }
}

public enum ATEMLink: Equatable {
    case idle
    case connecting
    case online
    case offline(String)
}

public struct ATEMLogEntry: Identifiable {
    public let id = UUID()
    public let time: Date
    /// The four-letter ATEM command, such as CPvI (set preview).
    public let command: String
    public let data: [UInt8]
    /// False when the switcher wasn't connected, so nothing went out.
    public let sent: Bool

    /// A plain description, such as "Preview, M/E 1: input 9".
    public func describe(_ state: ATEMState) -> String {
        func u16(_ i: Int) -> Int { i + 1 < data.count ? Int(data[i]) << 8 | Int(data[i + 1]) : 0 }
        let me = "M/E \(Int(data.first ?? 0) + 1)"
        switch command {
        case "CPgI": return "Program, \(me): \(state.inputs[u16(2)]?.long ?? "input \(u16(2))")"
        case "CPvI": return "Preview, \(me): \(state.inputs[u16(2)]?.long ?? "input \(u16(2))")"
        case "DCut": return "Cut, \(me)"
        case "DAut": return "Auto transition, \(me)"
        case "CTPs": return "T-bar, \(me): \(u16(2) / 100)%"
        case "CTTp": return "Transition settings, M/E \(Int(data.count > 1 ? data[1] : 0) + 1)"
        case "CTMx": return "Mix rate, \(me): \(data.count > 1 ? Int(data[1]) : 0) frames"
        case "CKOn": return "Key \(Int(data.count > 1 ? data[1] : 0) + 1) \(data.count > 2 && data[2] != 0 ? "on" : "off"), \(me)"
        case "CDsL": return "DSK \(Int(data.first ?? 0) + 1) \(data.count > 1 && data[1] != 0 ? "on" : "off")"
        case "CDsT": return "DSK \(Int(data.first ?? 0) + 1) tie \(data.count > 1 && data[1] != 0 ? "on" : "off")"
        case "DDsA": return "DSK \(Int(data.first ?? 0) + 1) auto"
        case "FtbA": return "Fade to black, \(me)"
        case "CAuS": return "Aux \(Int(data.count > 1 ? data[1] : 0) + 1): \(state.inputs[u16(2)]?.long ?? "input \(u16(2))")"
        case "MAct": return u16(0) == 0xFFFF ? "Stop macro" : "Run macro \(u16(0) + 1)"
        case "StrR": return "Streaming \(data.first == 1 ? "start" : "stop")"
        case "RcTM": return "Recording \(data.first == 1 ? "start" : "stop")"
        default: return command
        }
    }
}

public enum SwitcherKind: Equatable {
    case atem
    case tricaster
}

/// The switcher: an ATEM over its own protocol, or a TriCaster (TriCaster.swift) when the
/// address answers on the TriCaster's API port. Both fill the same state and take the same
/// commands.
public final class ATEMClient: ObservableObject {
    @Published public private(set) var state = ATEMState()
    @Published public private(set) var link: ATEMLink = .idle
    @Published public private(set) var host = ""
    @Published public private(set) var kind: SwitcherKind = .atem
    /// Where a TriCaster's API listens. Self-tests point it at a pretend TriCaster.
    public static var triCasterPort: UInt16 = 5952
    /// Which end of the T-bar is at rest, per M/E. Flips when a transition
    /// finishes, as on a hardware panel.
    @Published public private(set) var tbarAtTop: [Int: Bool] = [:]
    /// The last commands this app sent (or tried to send while offline), newest last,
    /// for the Status window.
    @Published public private(set) var sentLog: [ATEMLogEntry] = []

    private let queue = DispatchQueue(label: "cuevideo.atem")
    private var conn: NWConnection?
    private var target = ""
    private var port: UInt16 = 9910
    private var session: UInt16 = 0x53AB
    private var localID: UInt16 = 0
    private var inFlight: [(id: UInt16, data: Data, sent: Double, tries: Int)] = []
    private var lastInbound = 0.0
    private var lastRemoteID: UInt16?
    private var lastHello = 0.0
    private var connected = false
    private var ready = false
    private var timer: DispatchSourceTimer?
    private var s = ATEMState()
    private var lastPosition: [Int: Double] = [:]
    /// The TriCaster connection, when the switcher is one. Only touched on the main thread.
    private var tc: TriCasterLink?
    /// Counts connect calls, so a slow TriCaster probe can't act for an old address.
    private var generation = 0
    private var lastProbe = 0.0

    private enum Flag {
        static let ackRequest: UInt8 = 0x01, newSession: UInt8 = 0x02, retransmit: UInt8 = 0x04
        static let retransmitRequest: UInt8 = 0x08, ackReply: UInt8 = 0x10
    }
    private static let hello: [UInt8] = [0x10, 0x14, 0x53, 0xAB, 0, 0, 0, 0, 0, 0x3A, 0, 0, 0x01, 0, 0, 0, 0, 0, 0, 0]

    public init() {}

    // MARK: Connection

    /// Connects to the switcher at this address. A TriCaster is tried first (its API answers
    /// at once over HTTP); anything else is taken to be an ATEM.
    public func connect(_ host: String, port: UInt16 = 9910) {
        let h = host.trimmingCharacters(in: .whitespaces)
        self.host = h
        link = h.isEmpty ? .idle : .connecting
        generation += 1
        let g = generation
        stopTriCaster()
        queue.async {
            self.target = ""
            self.s = ATEMState()
            self.publish()
        }
        guard !h.isEmpty else { return }
        TriCasterLink.probe(h, port: Self.triCasterPort) { found in
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                if let found { self.startTriCaster(h, found) } else { self.startATEM(h, port: port) }
            }
        }
    }

    private func startATEM(_ h: String, port: UInt16) {
        kind = .atem
        queue.async {
            self.target = h
            self.port = port
            if self.timer == nil {
                let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                self.timer = t
            }
            self.open()
        }
    }

    private func startTriCaster(_ h: String, _ info: (product: String, version: String, frameRate: Double)) {
        queue.async {
            self.target = ""
            self.timer?.cancel(); self.timer = nil
            self.conn?.cancel(); self.conn = nil
            self.connected = false; self.ready = false
        }
        let link = TriCasterLink(host: h, port: Self.triCasterPort)
        link.onState = { [weak self] st in DispatchQueue.main.async { if self?.state != st { self?.state = st } } }
        link.onLink = { [weak self, weak link] l in
            DispatchQueue.main.async { if let self, self.tc === link, self.link != l { self.link = l } }
        }
        link.onLog = { [weak self] e in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sentLog.append(e)
                if self.sentLog.count > 60 { self.sentLog.removeFirst(self.sentLog.count - 60) }
            }
        }
        tc = link
        kind = .tricaster
        link.start(product: info.product, version: info.version, frameRate: info.frameRate)
    }

    private func stopTriCaster() {
        tc?.stop()
        tc = nil
    }

    public func disconnect() {
        host = ""
        link = .idle
        generation += 1
        stopTriCaster()
        queue.async {
            self.target = ""
            self.timer?.cancel(); self.timer = nil
            self.conn?.cancel(); self.conn = nil
            self.connected = false; self.ready = false
        }
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func open() {
        conn?.cancel()
        connected = false
        ready = false
        inFlight.removeAll()
        session = 0x53AB
        localID = 0
        guard !target.isEmpty, let p = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(target), port: p, using: .udp)
        c.start(queue: queue)
        conn = c
        receive(c)
        lastHello = now()
        lastInbound = now()
        c.send(content: Data(Self.hello), completion: .contentProcessed { _ in })
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, c === self.conn else { return }
            if let data, data.count >= 12 { self.handle([UInt8](data)) }
            if err == nil { self.receive(c) }
        }
    }

    private func setLink(_ l: ATEMLink) {
        DispatchQueue.main.async { if self.link != l && !self.target.isEmpty { self.link = l } }
    }

    private func tick() {
        guard !target.isEmpty else { return }
        let t = now()
        if t - lastInbound > 3 {
            // A TriCaster that was off when we connected may have come up since.
            if t - lastProbe > 6 {
                lastProbe = t
                let h = target
                TriCasterLink.probe(h, port: Self.triCasterPort) { found in
                    guard let found else { return }
                    DispatchQueue.main.async { if self.host == h && self.tc == nil { self.startTriCaster(h, found) } }
                }
            }
            if t - lastHello > 1.5 {
                setLink(.offline("No answer from \(target)"))
                open()
            }
            return
        }
        for i in inFlight.indices where t - inFlight[i].sent > 0.06 {
            if inFlight[i].tries >= 10 { setLink(.offline("The switcher stopped answering")); open(); return }
            var d = inFlight[i].data
            d[0] |= Flag.retransmit << 3
            conn?.send(content: d, completion: .contentProcessed { _ in })
            inFlight[i].sent = t
            inFlight[i].tries += 1
        }
    }

    private func handle(_ b: [UInt8]) {
        lastInbound = now()
        let flags = b[0] >> 3
        let length = Int(b[0] & 0x07) << 8 | Int(b[1])
        session = UInt16(b[2]) << 8 | UInt16(b[3])
        let remoteID = UInt16(b[10]) << 8 | UInt16(b[11])

        if flags & Flag.newSession != 0 {
            connected = true
            lastRemoteID = nil
            sendAck(remoteID)
            setLink(.connecting)
            return
        }
        if flags & Flag.ackRequest != 0 {
            sendAck(remoteID)
            // The switcher resends packets it isn't sure we got. Apply each packet once,
            // or an old update can land after a newer one and undo it.
            let fresh = lastRemoteID.map { (Int(remoteID) - Int($0) + 32768) % 32768 } ?? 1
            if fresh > 0 && fresh < 16384 {
                lastRemoteID = remoteID
                if length > 12 && b.count >= length { parse(Array(b[12..<length])) }
            }
        }
        if flags & Flag.ackReply != 0 {
            let acked = UInt16(b[4]) << 8 | UInt16(b[5])
            inFlight.removeAll { p in (Int(acked) - Int(p.id) + 32768) % 32768 < 16384 }
        }
        if flags & Flag.retransmitRequest != 0 {
            for p in inFlight { conn?.send(content: p.data, completion: .contentProcessed { _ in }) }
        }
    }

    private func sendAck(_ id: UInt16) {
        var p = [UInt8](repeating: 0, count: 12)
        p[0] = Flag.ackReply << 3
        p[1] = 12
        p[2] = UInt8(session >> 8); p[3] = UInt8(session & 0xFF)
        p[4] = UInt8(id >> 8); p[5] = UInt8(id & 0xFF)
        conn?.send(content: Data(p), completion: .contentProcessed { _ in })
    }

    // MARK: State from the switcher

    private func u16(_ d: [UInt8], _ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) << 8 | Int(d[i + 1]) : 0 }
    private func str(_ d: [UInt8], _ r: Range<Int>) -> String {
        guard r.lowerBound < d.count else { return "" }
        let slice = d[r.lowerBound..<min(r.upperBound, d.count)]
        return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
    }

    private func parse(_ payload: [UInt8]) {
        var off = 0
        while off + 8 <= payload.count {
            let len = u16(payload, off)
            guard len >= 8, off + len <= payload.count else { break }
            let name = String(bytes: payload[(off + 4)..<(off + 8)], encoding: .ascii) ?? ""
            apply(name, Array(payload[(off + 8)..<(off + len)]))
            off += len
        }
        if ready { publish() }
    }

    private let trace = ProcessInfo.processInfo.environment["CUEVIDEO_TRACE"].map { Set($0.split(separator: ",").map(String.init)) }

    private func apply(_ name: String, _ d: [UInt8]) {
        if let trace, trace.contains(name) {
            print(String(format: "TRACE %.3f %@ %@", now(), name, d.map { String(format: "%02x", $0) }.joined(separator: " ")))
            fflush(stdout)
        }
        switch name {
        case "InCm":
            ready = true
            setLink(.online)
        case "_ver" where d.count >= 4: s.version = "\(u16(d, 0)).\(u16(d, 2))"
        case "_pin": s.product = str(d, 0..<44)
        case "InPr" where d.count >= 26:
            let id = u16(d, 0)
            s.inputs[id] = ATEMInput(id: id, long: str(d, 2..<22), short: str(d, 22..<26))
        case "PrgI" where d.count >= 4:
            let me = Int(d[0]), src = u16(d, 2)
            // A finished transition changes program; the switcher doesn't always send a
            // last "not in transition" update after it, so end it here.
            if s.program[me] != src && s.inTransition[me] == true { endTransition(me) }
            s.program[me] = src
        case "PrvI" where d.count >= 4: s.preview[Int(d[0])] = u16(d, 2)
        case "TrPs" where d.count >= 6:
            let me = Int(d[0])
            let was = s.inTransition[me] ?? false
            let isOn = d[1] != 0
            let pos = Double(u16(d, 4)) / 10000
            if was && !isOn { endTransition(me) }
            s.inTransition[me] = isOn
            s.position[me] = pos
            lastPosition[me] = isOn ? pos : 0
        case "TrSS" where d.count >= 5:
            s.style[Int(d[0])] = Int(d[3])
            s.nextSelection[Int(d[0])] = Int(d[4])
        case "TMxP" where d.count >= 2: s.mixRate[Int(d[0])] = Int(d[1])
        case "KeOn" where d.count >= 3: s.keyOnAir[Int(d[0]), default: [:]][Int(d[1])] = d[2] != 0
        case "DskS" where d.count >= 3:
            s.dskOnAir[Int(d[0])] = d[1] != 0
            s.dskInTransition[Int(d[0])] = d[2] != 0
        case "DskP" where d.count >= 2: s.dskTie[Int(d[0])] = d[1] != 0
        case "KeBP" where d.count >= 10:
            s.keyFill[Int(d[0]), default: [:]][Int(d[1])] = u16(d, 6)
            s.keyCut[Int(d[0]), default: [:]][Int(d[1])] = u16(d, 8)
        case "DskB" where d.count >= 6:
            s.dskFill[Int(d[0])] = u16(d, 2)
            s.dskCut[Int(d[0])] = u16(d, 4)
        case "FtbS" where d.count >= 3:
            s.ftbBlack[Int(d[0])] = d[1] != 0
            s.ftbInTransition[Int(d[0])] = d[2] != 0
        case "AuxS" where d.count >= 4: s.aux[Int(d[0])] = u16(d, 2)
        case "MPrp" where d.count >= 8:
            let i = u16(d, 0)
            if d[2] != 0 {
                let n = str(d, 8..<(8 + u16(d, 4)))
                s.macros[i] = n.isEmpty ? "Macro \(i + 1)" : n
            } else {
                s.macros[i] = nil
            }
        case "MRPr" where d.count >= 4: s.macroRunning = d[0] & 1 != 0 ? u16(d, 2) : nil
        case "StRS" where d.count >= 2: s.streamStatus = u16(d, 0); s.hasStreaming = true
        case "RTMS" where d.count >= 2: s.recordStatus = u16(d, 0); s.hasRecording = true
        case "TlSr" where d.count >= 2:
            let n = u16(d, 0)
            var t: [Int: UInt8] = [:]
            for i in 0..<n where 2 + i * 3 + 2 < d.count { t[u16(d, 2 + i * 3)] = d[2 + i * 3 + 2] }
            s.tally = t
        default: break
        }
    }

    /// The T-bar's rest end flips when a transition ran past halfway, as on a hardware panel.
    private func endTransition(_ me: Int) {
        if (lastPosition[me] ?? 0) > 0.5 {
            DispatchQueue.main.async { self.tbarAtTop[me] = !(self.tbarAtTop[me] ?? false) }
        }
        s.inTransition[me] = false
        s.position[me] = 0
        lastPosition[me] = 0
    }

    private func publish() {
        let snap = s
        DispatchQueue.main.async { if self.state != snap { self.state = snap } }
    }

    // MARK: Commands

    private func command(_ name: String, _ data: [UInt8]) -> [UInt8] {
        let len = 8 + data.count
        return [UInt8(len >> 8), UInt8(len & 0xFF), 0, 0] + Array(name.utf8) + data
    }

    private func send(_ name: String, _ data: [UInt8]) {
        queue.async {
            let ok = self.connected && self.ready
            let entry = ATEMLogEntry(time: Date(), command: name, data: data, sent: ok)
            DispatchQueue.main.async {
                self.sentLog.append(entry)
                if self.sentLog.count > 60 { self.sentLog.removeFirst(self.sentLog.count - 60) }
            }
            guard ok else { return }
            let commands = self.command(name, data)
            self.localID = (self.localID + 1) % 32768
            let len = 12 + commands.count
            var p = [UInt8](repeating: 0, count: 12)
            p[0] = (Flag.ackRequest << 3) | UInt8((len >> 8) & 0x07)
            p[1] = UInt8(len & 0xFF)
            p[2] = UInt8(self.session >> 8); p[3] = UInt8(self.session & 0xFF)
            p[10] = UInt8(self.localID >> 8); p[11] = UInt8(self.localID & 0xFF)
            let packet = Data(p + commands)
            self.inFlight.append((self.localID, packet, self.now(), 0))
            self.conn?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    private func hl(_ v: Int) -> [UInt8] { let c = UInt16(clamping: max(0, v)); return [UInt8(c >> 8), UInt8(c & 0xFF)] }
    private func b(_ v: Int) -> UInt8 { UInt8(clamping: max(0, v)) }

    public func setProgram(_ source: Int, me: Int = 0) { if let tc { tc.setProgram(source, me: me) } else { send("CPgI", [b(me), 0] + hl(source)) } }
    public func setPreview(_ source: Int, me: Int = 0) { if let tc { tc.setPreview(source, me: me) } else { send("CPvI", [b(me), 0] + hl(source)) } }
    public func cut(me: Int = 0) { if let tc { tc.cut(me: me) } else { send("DCut", [b(me), 0, 0, 0]) } }
    public func auto(me: Int = 0) { if let tc { tc.auto(me: me) } else { send("DAut", [b(me), 0, 0, 0]) } }
    /// 0 to 1 from the start of the transition.
    public func setPosition(_ v: Double, me: Int = 0) { if let tc { tc.setPosition(v, me: me) } else { send("CTPs", [b(me), 0] + hl(Int((min(1, max(0, v)) * 10000).rounded()))) } }
    public func setStyle(_ style: Int, me: Int = 0) { if let tc { tc.setStyle(style, me: me) } else { send("CTTp", [1, b(me), b(style), 0]) } }
    public func setNextSelection(_ mask: Int, me: Int = 0) { if let tc { tc.setNextSelection(mask, me: me) } else { send("CTTp", [2, b(me), 0, b(max(1, mask))]) } }
    public func setMixRate(_ frames: Int, me: Int = 0) { if let tc { tc.setMixRate(frames, me: me) } else { send("CTMx", [b(me), b(min(250, max(1, frames))), 0, 0]) } }
    public func setKeyOnAir(_ keyer: Int, _ on: Bool, me: Int = 0) { if let tc { tc.setKeyOnAir(keyer, on, me: me) } else { send("CKOn", [b(me), b(keyer), on ? 1 : 0, 0]) } }
    public func setDSKOnAir(_ dsk: Int, _ on: Bool) { if let tc { tc.setDSKOnAir(dsk, on) } else { send("CDsL", [b(dsk), on ? 1 : 0, 0, 0]) } }
    public func setDSKTie(_ dsk: Int, _ on: Bool) { if let tc { tc.setDSKTie(dsk, on) } else { send("CDsT", [b(dsk), on ? 1 : 0, 0, 0]) } }
    public func dskAuto(_ dsk: Int) { if let tc { tc.dskAuto(dsk) } else { send("DDsA", [b(dsk), 0, 0, 0]) } }
    public func fadeToBlack(me: Int = 0) { if let tc { tc.fadeToBlack(me: me) } else { send("FtbA", [b(me), 0, 0, 0]) } }
    public func setAux(_ aux: Int, _ source: Int) { if let tc { tc.setAux(aux, source) } else { send("CAuS", [1, b(aux)] + hl(source)) } }
    public func runMacro(_ index: Int) { if let tc { tc.runMacro(index) } else { send("MAct", hl(index) + [0, 0]) } }
    public func stopMacro() { if let tc { tc.stopMacro() } else { send("MAct", [0xFF, 0xFF, 1, 0]) } }
    public func setStreaming(_ on: Bool) { if let tc { tc.setStreaming(on) } else { send("StrR", [on ? 1 : 0, 0, 0, 0]) } }
    public func setRecording(_ on: Bool) { if let tc { tc.setRecording(on) } else { send("RcTM", [on ? 1 : 0, 0, 0, 0]) } }
}
