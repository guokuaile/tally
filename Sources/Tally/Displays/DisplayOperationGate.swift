import Foundation

@MainActor
final class DisplayOperationGate {
    static let shared = DisplayOperationGate()
    private(set) var busy = false
    func enter() throws {
        guard !busy else { throw DisplayFailure("另一项显示器操作正在进行") }
        busy = true
    }
    func leave() { busy = false }
}
