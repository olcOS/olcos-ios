import Foundation

// MARK: - Vp8Tuning
//
// MTS Link carries `vp8channel` alone, and the core's release gate measures it
// at about 15 Mbit/s down with `vp8: { fps: 60, batch_size: 64 }`. A frame
// leaves every 1/fps seconds carrying up to `batch_size` packets, so the
// ceiling scales roughly with the frame rate — the 30 / 64 the settings default
// to leaves half of it unused. Whenever an MTS Link room is involved the
// effective numbers are therefore 60 and at least 64; every other protocol
// keeps the person's numbers untouched.
//
// One rule, used by the server configs an MTS Link room is written into
// (SSHRunner.installEnv / addCarrierEnv / reconfigureScript) and by the phone's
// engine start (OlcrtcEngine, the VPN configuration).
enum Vp8Tuning {
    static let mtsLinkFPS = 60
    static let mtsLinkMinBatch = 64

    /// PURE. `carriers` are the protocols of every lane the numbers apply to.
    static func effective(carriers: [String], fps: Int, batch: Int) -> (fps: Int, batch: Int) {
        guard carriers.contains("mtslink") else { return (fps, batch) }
        return (mtsLinkFPS, max(batch, mtsLinkMinBatch))
    }

    /// PURE. The numbers ONE lane runs on. Every lane is a runtime of its own,
    /// so a whole-server connection with an MTS Link room among others lifts
    /// that room only: the VK or Jitsi lane beside it keeps the person's
    /// numbers instead of 60 frames a second it has no use for.
    static func forLane(carrier: String, fps: Int, batch: Int) -> (fps: Int, batch: Int) {
        effective(carriers: [carrier], fps: fps, batch: batch)
    }
}
