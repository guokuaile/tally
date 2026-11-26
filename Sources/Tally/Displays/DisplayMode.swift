import Foundation

struct DisplayFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DisplayModeSelection: Codable, Equatable, Hashable, Identifiable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var id: String { "\(width)x\(height):\(pixelWidth)x\(pixelHeight):\(refreshRate)" }
    var isHiDPI: Bool { pixelWidth > width || pixelHeight > height }
    var label: String {
        let rate = refreshRate == 0 ? "系统默认" : "\(Int(refreshRate.rounded())) Hz"
        return "\(width)×\(height) · \(pixelWidth)×\(pixelHeight) · \(isHiDPI ? "HiDPI" : "普通") · \(rate)"
    }
    var isValid: Bool {
        width > 0 && height > 0 && pixelWidth > 0 && pixelHeight > 0 &&
        refreshRate.isFinite && refreshRate >= 0
    }
    func matches(_ other: Self) -> Bool {
        guard isValid, other.isValid else { return false }
        return width == other.width && height == other.height && pixelWidth == other.pixelWidth &&
            pixelHeight == other.pixelHeight &&
            (refreshRate == 0 || other.refreshRate == 0
             ? refreshRate == other.refreshRate : abs(refreshRate - other.refreshRate) < 1)
    }
}

struct DisplayUndoPoint: Codable, Equatable {
    var before: DisplayModeSelection
    var applied: DisplayModeSelection
}

struct DisplayUndoRecord: Codable, Equatable {
    var confirmed: DisplayUndoPoint?
    var pending: DisplayUndoPoint?
}

struct DisplaySnapshot: Identifiable, Equatable {
    var id: String
    var name: String
    var vendor: UInt32
    var product: UInt32
    var builtin: Bool
    var mirrored: Bool
    var current: DisplayModeSelection
    var modes: [DisplayModeSelection]

    func matching(_ selected: DisplayModeSelection) -> DisplayModeSelection? {
        modes.filter { $0.matches(selected) }.min {
            abs($0.refreshRate - selected.refreshRate) < abs($1.refreshRate - selected.refreshRate)
        }
    }
}
