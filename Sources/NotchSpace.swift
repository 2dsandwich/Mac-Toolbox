import AppKit

// A Space of its own above every other, as notch apps do (NotchDrop, boring.notch): a window in it stays fixed at the
// notch while you swipe between Spaces, enter full screen or open Mission Control, like the menu bar. Private SkyLight
// calls (no public API keeps a window out of the Space-switch animation); the app is built from source, not the App Store.

@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSpaceCreate") private func CGSSpaceCreate(_ cid: Int32, _ flag: Int, _ options: NSDictionary?) -> Int
@_silgen_name("CGSSpaceSetAbsoluteLevel") private func CGSSpaceSetAbsoluteLevel(_ cid: Int32, _ space: Int, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces") private func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces") private func CGSShowSpaces(_ cid: Int32, _ spaces: NSArray)

enum NotchSpace {
    private static let id: Int = {
        let cid = _CGSDefaultConnection()
        let space = CGSSpaceCreate(cid, 0x1, nil)
        CGSSpaceSetAbsoluteLevel(cid, space, Int(Int32.max))
        CGSShowSpaces(cid, [space])
        return space
    }()

    /// Puts the window in the top Space (once is enough; it stays there while hidden and shown).
    static func pin(_ window: NSWindow) {
        CGSAddWindowsToSpaces(_CGSDefaultConnection(), [window.windowNumber], [id])
    }
}
