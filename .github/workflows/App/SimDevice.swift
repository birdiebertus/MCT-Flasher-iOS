// Offline ECU simulator - lets the app be demo/proven TODAY without hardware
// (same idea as the proven szsim: choreography + injectable flash content)
import Foundation

final class SimDevice: ECULink {
    private var flash: [UInt8]
    private var rx = Data()
    private let lock = NSLock()
    var onWrite: ((Data) -> Void)? = nil
    let modelId = Array("HSG206".utf8)
    private var dancing = false
    private var danceAddr = 0

    init(flash: [UInt8]? = nil) {
        if let f = flash, f.count == 524288 {
            self.flash = f
        } else {
            var f = [UInt8](repeating: 0xFF, count: 524288)
            // put a fake identity in, like the real ECU
            let id = Array("HSG206".utf8); for (i, b) in id.enumerated() { f[0x3FFFA + i] = b }
            let ser = Array("F6522A71".utf8); for (i, b) in ser.enumerated() { f[0x40040 + i] = b }
            let mdl = Array("---00L98          SP51 ".utf8); for (i, b) in mdl.enumerated() { f[0x46F7A + i] = b }
            f[0x3FFC1] = 0x8B; f[0x3FFC2] = 0x04
            self.flash = f
        }
    }

    private func hexRecord(_ ofs: Int, _ bytes: [UInt8]) -> Data {
        var rec = Data([0x3A, UInt8(bytes.count & 0xFF),
                        UInt8((ofs >> 8) & 0xFF), UInt8(ofs & 0xFF), 0x00])
        rec.append(bytes)
        var chk = 0
        for k in 1..<rec.count { chk = (chk - Int(rec[k])) & 0xFF }
        rec.append(UInt8(chk))
        return rec
    }

    func writeOne(_ bytes: Data) async throws {
        onWrite?(bytes)
        if bytes == Data([0x10]) {
            // SM3-style wake arm: expect [00 01] next
            dancing = false
        }
        if bytes == Data([0x00, 0x01]) {
            lock.lock(); rx.append(0x05); lock.unlock()      // WAKE OK
        }
        if bytes.first == 0x00 && bytes.count == 1 {         // seed request
            lock.lock(); rx.append(0x1A); lock.unlock()
        }
        if let b = bytes.first, b == 0x80, bytes.count == 6 {
            // dance address frame: v=bytes[1..2] BE
            dancing = true
            danceAddr = (Int(bytes[1]) << 8 | Int(bytes[2])) << 8   // v=4n -> addr = v<<8
        }
        if bytes == Data([0xFF]) && dancing {                 // GO -> emit block stream
            let per = 64
            var ofs = danceAddr
            var emitted = 0
            var out = Data()
            // ESA record for this 64 KB boundary
            let seg = UInt16(ofs >> 16)
            var esa = Data([0x3A, 0x02, 0x00, 0x00, 0x02, UInt8((seg >> 8) & 0xFF), UInt8(seg & 0xFF)])
            var chk = 0; for k in 1..<esa.count { chk = (chk - Int(esa[k])) & 0xFF }
            esa.append(UInt8(chk)); out.append(esa)
            while emitted < 1299 - 12 {
                let n = min(per, 1299 - 12 - emitted)
                out.append(hexRecord(ofs & 0xFFFF, Array(flash[min(ofs, 524287)..<(min(ofs + n, 524287))] )))
                ofs += n; emitted += n
            }
            dancing = false
            lock.lock(); rx.append(out); lock.unlock()
        }
    }

    func readMsg(timeoutMs: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            lock.lock()
            if !rx.isEmpty {
                // return one "message": until next 3A? keep single bytes separate
                let first = rx.prefix(1)
                rx.removeFirst(1)
                lock.unlock()
                if first == Data([0x3A]) {
                    // accumulate a full record
                    lock.lock(); let rest = rx; rx = Data(); lock.unlock()
                    var rec = first
                    // find record length: 3A cnt ... chk
                    if rest.count > 1 {
                        let cnt = Int(rest[0])
                        let need = 6 + cnt
                        rec.append(rest.prefix(need))
                        lock.lock(); rx.insert(contentsOf: rest.dropFirst(need), at: 0); lock.unlock()
                    }
                    return rec
                }
                return first
            }
            lock.unlock()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return Data()
    }

    func readAvailable(timeoutMs: Int) async throws -> [Data] {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var out: [Data] = []
        while Date() < deadline {
            let one = try await readMsg(timeoutMs: 30)
            if one.isEmpty { break }
            out.append(one)
        }
        return out
    }

    func setVPP(on: Bool, mv: UInt32) async throws {}
    func ecuPower(on: Bool) async throws {}
    func close() async {}
}
