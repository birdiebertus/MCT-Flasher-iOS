# MCT-Flasher iOS (KokusanFlasher MOBILE)

De flasher op je iPhone: ID / READ / WRITE / VERIFY voor de MH8102F
(Suzuki/Yamaha), zelfde bewezen sequenties als de Windows master.

## Vandaag testen (SIM-modus)
De app start in **SIM mode** (ingebouwde ECU-simulator, zoals onze szsim):
ID en READ lopen volledig, geen hardware nodig. Zo bewijs je de app vandaag
op je eigen iPhone.

## Build zonder Mac
1. Zet deze map in een GitHub-repo (push).
2. GitHub Actions (macos-14) bouwt automatisch een **unsigned .ipa**
   (workflow `build.yml`, artifact `MCTFlasher-ipa`).
3. Download de .ipa op de PC en installeer met **Sideloadly**
   (gratis Apple ID, kabel naar de iPhone; iOS vraagt daarna even om
   Developer Mode / toestemming voor de app).

## De echte SM3 Wi-Fi-route
- De SM3 moet in de telefoon-modus als **Legacy Access Point** draaien
  (config-tool: Wi-Fi Connection Mode = 1) - de iPhone kan geen Wi-Fi-Direct;
  internet op de telefoon blijft gewoon via mobiele data.
- De app-client (`Sm3WiFiClient.swift`) heeft de gedecodeerde lagen al:
  subnet van het apparaat, TCP-poort 777, `ff ff`-framing, wake/config-payloads
  (`01 24 f4 00` = 62500), ECU-power SPV(15) facts.
- Wacht op "decoder dag 2": de per-op token-herleiding. Dan gaat de
  SIM-toggle naar echte ECU-werk via de SM3 - geen PC. (De wire-captures en
  de correlator `sm3_wire_decode.py` staan klaar in de Windows-sessie.)

## Bestanden
- `App/MCTFlasherApp.swift` - entry
- `App/ContentView.swift` - UI (ID/READ/WRITE/VERIFY, progress, log)
- `App/FlashCore.swift` - MH8102F-kern, 1:1 port van de bewezen Python
  (wake/keys/dance/HEX-parser/checksum-preservatie)
- `App/SimDevice.swift` - offline ECU-simulator (vandaag-test)
- `App/Sm3WiFiClient.swift` - SM3 Wi-Fi-client met decoder-hooks
- `.github/workflows/build.yml` - ipa-build op GitHub (macOS)
- `project.yml` - XcodeGen project
