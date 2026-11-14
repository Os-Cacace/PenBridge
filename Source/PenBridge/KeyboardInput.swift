// Routes input to the on-screen keyboard. Runs on the input thread.
//
// Touch and pen come from the digitizer reports, so several fingers can type at once
// and VoodooI2C's own click and hold handling never gets in the way. The cursor
// events VoodooI2C makes for those touches are dropped while they are over the
// keyboard (mouse-ups always pass). A trackpad or mouse press on the keyboard has
// no digitizer report, so it becomes a contact of its own (id -1).
import Foundation
import CoreGraphics

/// The keyboard's key area in global display coordinates, shared with the main thread.
final class KeyboardShared {
    private let lock = NSLock()
    private var rect = CGRect.null
    var frame: CGRect { lock.lock(); defer { lock.unlock() }; return rect }
    func setFrame(_ r: CGRect) { lock.lock(); rect = r; lock.unlock() }

    /// Modifiers the keyboard holds down; the event tap adds them to every event.
    private var held: CGEventFlags = []
    var heldFlags: CGEventFlags {
        get { lock.lock(); defer { lock.unlock() }; return held }
        set { lock.lock(); held = newValue; lock.unlock() }
    }
}
let keyboardShared = KeyboardShared()

final class KeyboardRouter {
    private var ownedTouches = Set<Int>()
    private var outsideTouches = Set<Int>()
    private var penOwned = false
    private var mouseOwned = false
    private var swallowing = false        // cursor events of a keyboard touch, until the button is up
    private var lastPointer = CGPoint.zero // where the pointer was before the keyboard was touched
    private var pointerSaved = false
    private var restoreTimer: Timer?
    private var lastOutsideTap = Date.distantPast

    static let penID = -2, mouseID = -1

    private func send(_ f: @escaping (KeyboardController) -> Void) {
        DispatchQueue.main.async { f(KeyboardController.shared) }
    }

    // MARK: Touch frames

    /// Takes the contacts that belong to the keyboard and returns the rest for gestures.
    func route(_ contacts: [Contact], toScreen: (Contact) -> CGPoint) -> [Contact] {
        let frame = keyboardShared.frame
        if frame.isNull && ownedTouches.isEmpty { outsideTouches.removeAll(); return contacts }
        var rest: [Contact] = [], seen = Set<Int>()
        for c in contacts {
            seen.insert(c.id)
            let p = toScreen(c)
            if ownedTouches.contains(c.id) {
                send { $0.contactMoved(c.id, to: p) }
            } else if !outsideTouches.contains(c.id) && frame.contains(p) {
                ownedTouches.insert(c.id)
                savePointer()
                send { $0.contactBegan(c.id, at: p) }
            } else {
                outsideTouches.insert(c.id)
                rest.append(c)
            }
        }
        for id in ownedTouches where !seen.contains(id) {
            ownedTouches.remove(id)
            send { $0.contactEnded(id) }
        }
        outsideTouches.formIntersection(seen)
        if ownedTouches.isEmpty && pointerSaved { scheduleRestore() }
        return rest
    }

    // MARK: Pen

    func pen(touching: Bool, at p: CGPoint) {
        if penOwned {
            if touching { send { $0.contactMoved(KeyboardRouter.penID, to: p) } }
            else { penOwned = false; send { $0.contactEnded(KeyboardRouter.penID) } }
        } else if touching && !wasPenTouching {
            if keyboardShared.frame.contains(p) {
                penOwned = true
                send { $0.contactBegan(KeyboardRouter.penID, at: p) }
            } else {
                outsideTap()
            }
        }
        wasPenTouching = touching
    }
    private var wasPenTouching = false

    // MARK: Cursor events

    /// nil: not the keyboard's business. true: pass the event on. false: drop it.
    func mouseEvent(_ type: CGEventType, _ ev: CGEvent) -> Bool? {
        let frame = keyboardShared.frame
        let loc = ev.location
        let busy = penOwned || !ownedTouches.isEmpty
        switch type {
        case .mouseMoved:
            if !busy && !frame.contains(loc) && !pointerSaved { lastPointer = loc }
            return nil
        case .leftMouseDown, .rightMouseDown:
            guard busy || (!frame.isNull && frame.contains(loc)) else {
                lastPointer = loc
                if fromDigitizer() { outsideTap() } else {
                    send { $0.focusMayHaveChanged(); $0.scheduleFocusCheck(fromTouch: false) }
                }
                return nil
            }
            if busy || fromDigitizer() { swallowing = true; return false }
            guard type == .leftMouseDown else { return false }
            mouseOwned = true
            send { $0.contactBegan(KeyboardRouter.mouseID, at: loc) }
            return false
        case .leftMouseDragged, .rightMouseDragged:
            if mouseOwned { send { $0.contactMoved(KeyboardRouter.mouseID, to: loc) }; return false }
            return swallowing || busy ? false : nil
        case .leftMouseUp, .rightMouseUp:
            if mouseOwned { mouseOwned = false; send { $0.contactEnded(KeyboardRouter.mouseID) }; return true }
            if swallowing { swallowing = false; return true }
            // A click elsewhere used up a one-shot ⌘ ⌥ ⌃ (after this release goes out).
            if !keyboardShared.heldFlags.isEmpty { send { $0.clickEnded() } }
            return nil
        default:
            return nil
        }
    }

    private func fromDigitizer() -> Bool {
        penIsActive() || Date().timeIntervalSince(touch.lastReport) < 0.08
    }

    // MARK: Pointer and auto-show

    /// Touching the keyboard moves the pointer onto it; put it back afterwards.
    private func savePointer() {
        restoreTimer?.invalidate(); restoreTimer = nil
        pointerSaved = true
    }

    private func scheduleRestore() {
        restoreTimer?.invalidate()
        restoreTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
            guard let self, self.ownedTouches.isEmpty else { return }
            CGWarpMouseCursorPosition(self.lastPointer)
            CGAssociateMouseAndMouseCursorPosition(1)
            self.pointerSaved = false
        }
    }

    /// A finger or the pen tapped outside the keyboard: the text field may have changed.
    private func outsideTap() {
        let now = Date()
        guard now.timeIntervalSince(lastOutsideTap) > 0.05 else { return }
        lastOutsideTap = now
        send { $0.focusMayHaveChanged(); $0.scheduleFocusCheck(fromTouch: true) }
    }
}

let keyboardRouter = KeyboardRouter()
