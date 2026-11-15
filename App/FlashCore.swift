// MH8102F flash core - 1:1 port of the PROVEN python client (flashercore/protocol/mh8102f.py)
// Sequences, timings and checksums come from the live-proven SM3/Tactrix routes.
import Foundation

enum FlasherError: Error, LocalizedError {
    case msg(String)
    var errorDescription: String? { case .msg(let m) = self; return m }
}

protocol ECULink: AnyObject {
    func writeOne(_ bytes: Data) async throws
    func readMsg(timeoutMs: Int) async throws -> Data   // one RX message (TX-echo skipped)
    func readAvailable(timeoutMs: Int) async throws -> [Data]
    func setVPP(on: Bool, mv: UInt32) async throws
    func ecuPower(on: Bool) async throws
    func close() async
}

final class FlashCore {
    static let blockSize = 1299
    static let blocks = 512
    static let firmwareSize = 524288
    static let keys: [UInt8] = [0x9B, 0xEC, 0x2B, 0x8B, 0xD4, 0x86]
    static let slowCadenceMs = 505
    static let wakeGapMs = 805

    let link: ECULink
    var log: (String) -> Void
    var progress: (Int, String) -> Bool   // return false = cancel
    var idField: (hi: UInt8, lo: UInt8)? = nil

    init(link: ECULink, log: @escaping (String) -> Void, progress: @escaping (Int, String) -> Bool) {
        self.link = link
        self.log = log
        self.progress = progress
    }

    private func ms(_ v: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(v * 1_000_000))
    }

    /// SM3 bench wake: 0x10 + 505 ms + [00 01] -> ECU sends 05
    func wake() async throws {
        try await link.writeOne(Data([0x10]))
        await ms(505)
        try await link.writeOne(Data([0x00, 0x01]))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let d = try await link.readMsg(timeoutMs: 250)
            if d == Data([0x05]) {
                log("WAKE OK (05)")
                return
            }
        }
        throw FlasherError.msg("WAKE: no 05 within 3 s")
    }

    /// Tactrix-style wake (SM3 wake is preferred on WiFi/USB bench)
    func wakeTactrix() async throws {
        try await link.writeOne(Data([0x10]))
        await ms(FlashCore.wakeGapMs)
        try await link.writeOne(Data([0xF0]))
        await ms(FlashCore.wakeGapMs)
        try await link.writeOne(Data([0xF0]))
        await ms(FlashCore.wakeGapMs - 100)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let d = try await link.readMsg(timeoutMs: 250)
            if d == Data([0x05]) { log("WAKE OK (05)"); return }
        }
        throw FlasherError.msg("WAKE: no 05 within 3 s")
    }

    func txSlow(_ b: UInt8) async throws {
        try await link.writeOne(Data([b]))
        await ms(FlashCore.slowCadenceMs)
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            let d = try await link.readMsg(timeoutMs: 150)
            if d == Data([b]) { return }         // ECU echoes every byte (proven)
        }
        throw FlasherError.msg(String(format: "no echo for %02X", b))
    }

    func handshake() async throws {
        try await link.writeOne(Data([0x00]))
        await ms(FlashCore.slowCadenceMs)
        let deadline = Date().addingTimeInterval(1.5)
        var sawSeed = false
        while Date() < deadline {
            let d = try await link.readMsg(timeoutMs: 150)
            if d == Data([0x1A]) { sawSeed = true; break }
        }
        guard sawSeed else { throw FlasherError.msg("no seed 0x1A") }
        for k in FlashCore.keys { try await txSlow(k) }
        try await txSlow(0x05)
        log("Security keys: accepted")
    }

    /// Deep ID blocks 255/256/283 (same as proven szid)
    func deepId() async throws -> (id: String, serial: String, model: String, idField: (UInt8, UInt8)) {
        log("---- DEEP ID: blocks 255/256/283 ----")
        var fw = [UInt8](repeating: 0xFF, count: FlashCore.firmwareSize)
        for n in [255, 256, 283] {
            try await danceBlock(n: n, fw: &fw)
            try Task.checkCancellation()
        }
        func text(_ a: Int, _ l: Int) -> String {
            let s = fw[a..<(a + l)].filter { $0 >= 0x20 && $0 < 0x7F }
            return String(bytes: s, encoding: .ascii) ?? ""
        }
        let idf = (fw[0x3FFC1], fw[0x3FFC2])
        idField = idf
        return (text(0x3FFFA, 6), text(0x40040, 8), text(0x46F7A, 17), idf)
    }

    /// One dance block: 6 fast bytes (v=4n, 16-bit BE) + GO + read 1299-byte HEX stream
    func danceBlock(n: Int, fw: inout [UInt8]) async throws {
        let v = 4 * n
        let frame: [UInt8] = [0x80, UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF), 0x00,
                              UInt8(((v + 3) >> 8) & 0xFF), UInt8((v + 3) & 0xFF)]
        for b in frame {
            try await link.writeOne(Data([b]))
            _ = try? await link.readMsg(timeoutMs: 8)   // discard line echo
        }
        try await link.writeOne(Data([0xFF]))           // GO pulse
        // read until 1299 bytes or 15 s
        var buf = Data()
        let deadline = Date().addingTimeInterval(15)
        while buf.count < FlashCore.blockSize && Date() < deadline {
            for d in try await link.readAvailable(timeoutMs: 200) {
                buf.append(d)
            }
        }
        guard buf.count >= FlashCore.blockSize else {
            throw FlasherError.msg("Block incomplete: \(buf.count)/\(FlashCore.blockSize)")
        }
        try feedHex(buf.prefix(FlashCore.blockSize), fw: &fw)
    }

    /// HEX record stream parser (ESA-persistent; identical semantics to the python port)
    func feedHex(_ block: Data, fw: inout [UInt8]) throws {
        var i = 0; let n = block.count
        var esa = 0
        while i < n {
            let b = block[i]
            if b == 0xFF { i += 1; continue }
            if b == 0x0D { i += 2; continue }
            guard b == 0x3A else { throw FlasherError.msg("HEX: unexpected byte \(b) at \(i)") }
            guard n - i >= 6 else { break }
            let cnt = Int(block[i + 1]); let need = 8 + cnt
            guard n - i >= need else { break }
            let typ = block[i + 4]
            if typ == 0x02 {
                esa = (Int(block[i + 5]) << 8 | Int(block[i + 6])) << 4
            } else if typ == 0x00 {
                let ofs = esa + (Int(block[i + 2]) << 8 | Int(block[i + 3]))
                guard ofs >= 0, ofs + cnt <= fw.count else {
                    throw FlasherError.msg("HEX: data outside buffer at \(ofs)")
                }
                var chk = 0
                for k in 1..<(5 + cnt) { chk = (chk - Int(block[i + k])) & 0xFF }
                guard chk == Int(block[i + cnt + 5]) else {
                    throw FlasherError.msg("HEX checksum error at \(i)")
                }
                for k in 0..<cnt { fw[ofs + k] = block[i + 5 + k] }
            }
            i += need
        }
    }

    /// Full 512-block read (proven structure; wifi-hardened per-block retry x2)
    func readAll() async throws -> Data {
        let fw0 = [UInt8](repeating: 0xFF, count: FlashCore.firmwareSize)
        var fw = fw0
        for n in 0..<FlashCore.blocks {
            var done = false
            for attempt in 1...2 {
                do { try await danceBlock(n: n, fw: &fw); done = true; break }
                catch FlasherError.msg(let m) where m.contains("Block incomplete") && attempt == 1 {
                    log("(block \(n): \(m) - retrying)"); await ms(250)
                }
            }
            guard done else { throw FlasherError.msg("block \(n) failed twice") }
            if n % 16 == 0 {
                log("> blocks \(n)/512")
            }
            if !progress(n * 100 / FlashCore.blocks, "READ") {
                throw FlasherError.msg("Cancelled.")
            }
        }
        idField = (fw[0x3FFC1], fw[0x3FFC2])
        return Data(fw)
    }
}
