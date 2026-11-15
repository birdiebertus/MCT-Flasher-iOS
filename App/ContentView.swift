// Main screen - ID / READ / WRITE / VERIFY with live progress (MCT style)
import SwiftUI

final class VM: ObservableObject {
    @Published var logLines: [String] = []
    @Published var progress: Double = 0
    @Published var phase = "Ready"
    @Published var busy = false
    @Published var simMode = true          // SIM = today-proven; SM3 = decoder-2 activates
    @Published var lastIdentity = ""

    func log(_ s: String) {
        DispatchQueue.main.async { self.logLines.append(s); if self.logLines.count > 400 { self.logLines.removeFirst(50) } }
    }

    func run(action: String) {
        guard !busy else { return }
        busy = true; progress = 0; phase = action
        let link: ECULink = simMode ? SimDevice() : Sm3WiFiClient()
        if let wifi = link as? Sm3WiFiClient { wifi.log = log }
        Task {
            do {
                if !simMode { try await (link as! Sm3WiFiClient).connect() }
                let core = FlashCore(link: link, log: { s in self.log(s) }) { p, ph in
                    DispatchQueue.main.async { self.progress = Double(p) / 100; self.phase = "\(ph) \(p)%" }
                    return true
                }
                // bench: automatic ECU power on the SM3 (red LED), like the proven flow
                if !simMode { try await link.ecuPower(on: true) }
                await core.wake()
                try await core.handshake()
                if action == "ID" {
                    let ident = try await core.deepId()
                    lastIdentity = "\(ident.id) · \(ident.serial) · [\(String(format: "%02X", ident.idField.0))][\(String(format: "%02X", ident.idField.1))]"
                    log("---- ECU ID: \(ident.id) ----")
                } else if action == "READ" {
                    let data = try await core.readAll()
                    log("---- READ COMPLETE: \(data.count) bytes ---- (ECU id-field \(String(format: "%02X %02X", core.idField?.hi ?? 0, core.idField?.lo ?? 0)))")
                }
                if !simMode { try await link.ecuPower(on: false) }
                await (link as? Sm3WiFiClient)?.close()
                log("\(action) finished.")
            } catch {
                log("ERROR: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { self.busy = false; self.phase = "Ready" }
        }
    }
}

struct ContentView: View {
    @StateObject var vm = VM()
    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Text("KokusanFlasher MOBILE").font(.title2).bold().foregroundColor(.white)
                    Text(vm.simMode ? "SIMULATOR (no hardware)" : "Scanmatik SM3 Wi-Fi (bench)")
                        .font(.footnote).foregroundColor(vm.simMode ? .yellow : .cyan)
                    ProgressView(value: vm.progress)
                        .progressViewStyle(.linear).tint(.cyan)
                    Text(vm.phase).font(.caption).foregroundColor(.white.opacity(0.8))
                }.padding().background(Color(red: 0, green: 0.06, blue: 0.25))

                Toggle("SIM mode (test today) / SM3 Wi-Fi", isOn: $vm.simMode)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    btn("ID") { vm.run(action: "ID") }
                    btn("READ") { vm.run(action: "READ") }
                    btn("WRITE") { vm.run(action: "WRITE") }
                    btn("VERIFY") { vm.run(action: "VERIFY") }
                }.padding(.horizontal)

                if !vm.lastIdentity.isEmpty {
                    Text(vm.lastIdentity).font(.subheadline).monospaced().foregroundColor(.blue)
                        .padding(.horizontal)
                }

                ScrollViewReader { sv in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.logLines.indices, id: \.self) { i in
                                Text(vm.logLines[i]).font(.caption2).monospaced()
                                    .foregroundColor(.primary).id(i)
                            }
                        }.padding(8)
                    }.background(Color.white).cornerRadius(10).padding(.horizontal)
                    .onChange(of: vm.logLines.count) { v in withAnimation { sv.scrollTo(v - 1) } }
                }
                Spacer(minLength: 0)
            }
            .background(Color(white: 0.94)).navigationBarHidden(true)
        }.navigationViewStyle(.stack)
    }

    func btn(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.headline).bold().foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(10)
                .background(Color(red: 0.06, green: 0.19, blue: 0.94)).cornerRadius(10)
                .opacity(vm.busy ? 0.5 : 1)
        }.disabled(vm.busy)
    }
}

