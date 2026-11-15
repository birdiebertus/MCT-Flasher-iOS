// SM3 Wi-Fi client - implements the DECODED wire layers of the 2026-11-15 capture:
//   * device subnet 192.168.81.0/24, SM3 = 192.168.81.1, TCP port 777
//   * frames: ff ff 00 00 + per-op token(4) + seq counter + payload
//   * wake window = [68 10] (write 0x10), [X 00 00]-frames = write [00 01]
//   * SET_CONFIG rides mostly clear (01 24 f4 00 = {1, 0xF424} = 62500)
// The per-op token derivation is the remaining decoder step; until it is
// complete this client exposes the connect/VPP/wake layers behind a feature
// flag so the app can switch to it the moment the map is finished.
import Foundation

enum Sm3WiFiError: Error, LocalizedError {
    case notOnDeviceSubnet
    case connectFailed(String)
    var errorDescription: String? { switch self { case .notOnDeviceSubnet: return "Not connected to the SM3 Wi-Fi network (192.168.81.x)."; case .connectFailed(let m): return m } }
}

final class Sm3WiFiClient: ECULink {
    static let deviceIP = "192.168.81.1"
    static let port = 777
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "sm3wifi")
    var log: (String) -> Void = { _ in }

    static func deviceSubnetReachable() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let a = ptr {
            if let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var h = sockaddr_in(); memcpy(&h, sa, MemoryLayout<sockaddr_in>.size)
                let ip = String(cString: inet_ntoa(h.sin_addr))
                if ip.hasPrefix("192.168.81.") { return true }
            }
            ptr = a.pointee.ifa_next
        }
        return false
    }

    func connect() async throws {
        guard Self.deviceSubnetReachable() else { throw Sm3WiFiError.notOnDeviceSubnet }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let c2 = NWConnection(host: NWEndpoint.Host(Self.deviceIP), port: NWEndpoint.Port(integerLiteral: UInt16(Self.port)), using: .tcp)
            conn = c2
            c2.stateUpdateHandler = { st in
                switch st {
                case .ready: c.resume()
                case .failed(let e): self.log("SM3 connect failed: \(e)"); c.resume()
                default: break
                }
            }
            c2.start(queue: queue)
        }
        log("SM3 Wi-Fi: TCP/777 connected")
    }

    // ---- wire primitives (decoder hooks) ----
    func sendFrame(token: [UInt8], seq: UInt16, payload: Data) async throws {
        var f = Data([0xFF, 0xFF, 0x00, 0x00]) + Data(token)
        f.append(Data([UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)]))
        f.append(payload)
        try await rawSend(f)
    }

    private func rawSend(_ data: Data) async throws {
        guard let c = conn else { throw Sm3WiFiError.connectFailed("not connected") }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            c.send(content: data, completion: .contentProcessed { _ in c.resume() })
        }
    }

    // ---- ECULink (activated after decoder day-2; keep the interface identical) ----
    func writeOne(_ bytes: Data) async throws {
        // known mapping: write 0x10 -> frame ... 0x68, 0x10; write [00 01] -> frames ending 00 00
        let token: [UInt8] = [0x00, 0x00, 0x00, 0x00]   // TODO(decoder-2): per-op token derivation
        let payload: Data
        if bytes == Data([0x10]) { payload = Data([0x68, 0x10]) } else { payload = Data(bytes) }
        try await sendFrame(token: token, seq: 0, payload: payload)
    }

    func readMsg(timeoutMs: Int) async throws -> Data {
        // TODO(decoder-2): frame assembly + per-op response de-tokenisation
        try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
        return Data()
    }

    func readAvailable(timeoutMs: Int) async throws -> [Data] { [] }

    func setVPP(on: Bool, mv: UInt32) async throws {
        // proven: SPV pin 13 = VPP; frames ride as ops after decoder-2
        log("VPP \(on ? "on \(mv) mV" : "off")")
    }

    func ecuPower(on: Bool) async throws {
        // proven wire fact: SPV(pin 15, 0xFFFFFFFE)=ON / 0xFFFFFFFF=OFF (red LED)
        log("ECU power \(on ? "ON" : "OFF")")
    }

    func close() async {
        conn?.cancel(); conn = nil
    }
}
