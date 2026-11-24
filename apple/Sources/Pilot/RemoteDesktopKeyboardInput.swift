import Foundation

/// Keeps dictated text and its later Enter attached to one authenticated VNC
/// connection. Reconnecting the same saved machine always creates a new ID.
@MainActor
final class RemoteDesktopKeyboardInput {
    struct KeyEvent: Equatable {
        let keysym: UInt32
        let isDown: Bool
    }

    typealias Sender = @MainActor (KeyEvent) -> Bool

    /// What ⌘V did with the Mac clipboard.
    enum PasteOutcome: Equatable {
        /// The text was typed into the remote computer.
        case typed
        /// Nothing local to paste; let the remote handle its own ⌘V.
        case forwardToRemote
        /// The text was refused (too long, or the connection dropped).
        case rejected
    }

    /// Pasted text is typed one key at a time, so bound what one ⌘V enqueues.
    static let maximumPasteScalars = 20_000

    private(set) var sessionID: UUID?
    private var sender: Sender?
    /// The Mac pasteboard change count when the user last copied or cut on the
    /// remote. Until the Mac clipboard changes again, the remote's is newer.
    private var remoteCopyChangeCount: Int?

    @discardableResult
    func beginSession(sender: @escaping Sender) -> UUID {
        let id = UUID()
        sessionID = id
        self.sender = sender
        remoteCopyChangeCount = nil
        return id
    }

    func endSession() {
        sessionID = nil
        sender = nil
        remoteCopyChangeCount = nil
    }

    func noteRemoteCopy(localChangeCount: Int) {
        guard sessionID != nil else { return }
        remoteCopyChangeCount = localChangeCount
    }

    /// Types the Mac clipboard into the remote in place of a forwarded ⌘V.
    ///
    /// Apple Screen Sharing ignores RFB cut-text from third-party clients, so
    /// keystrokes are the only way local text reaches it. `heldModifiers` are
    /// the Command keys the remote already believes are down; they are
    /// released first so the text is not read as shortcuts, then restored
    /// because the user is still holding them.
    func pasteText(_ text: String?, localChangeCount: Int, heldModifiers: [UInt32]) -> PasteOutcome {
        guard let sessionID, let sender, remoteCopyChangeCount != localChangeCount,
              let text, !text.isEmpty else { return .forwardToRemote }
        guard text.unicodeScalars.count <= Self.maximumPasteScalars else { return .rejected }
        let keysyms = Self.pasteKeysyms(text)
        guard !keysyms.isEmpty else { return .forwardToRemote }
        for modifier in heldModifiers {
            guard sender(KeyEvent(keysym: modifier, isDown: false)) else {
                endSession()
                return .rejected
            }
        }
        guard send(keysyms, sessionID: sessionID) else { return .rejected }
        for modifier in heldModifiers {
            guard sender(KeyEvent(keysym: modifier, isDown: true)) else {
                endSession()
                return .rejected
            }
        }
        return .typed
    }

    func sendText(_ text: String, sessionID: UUID) -> Bool {
        guard let keysyms = Self.textKeysyms(text), !keysyms.isEmpty else { return false }
        return send(keysyms, sessionID: sessionID)
    }

    func sendEnter(sessionID: UUID) -> Bool {
        send([0xff0d], sessionID: sessionID) // X11 XK_Return
    }

    private func send(_ keysyms: [UInt32], sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID, let sender else { return false }
        for keysym in keysyms {
            guard self.sessionID == sessionID else { return false }
            // Enqueue a complete press/release pair on the same connection,
            // without suspending between characters or the following Enter.
            let pressed = sender(KeyEvent(keysym: keysym, isDown: true))
            let released = sender(KeyEvent(keysym: keysym, isDown: false))
            guard pressed && released else {
                if self.sessionID == sessionID { endSession() }
                return false
            }
        }
        return self.sessionID == sessionID
    }

    /// Unlike dictation, a paste is an explicit request for this exact text:
    /// line breaks and tabs become real keys. Other controls are dropped.
    private static func pasteKeysyms(_ text: String) -> [UInt32] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .precomposedStringWithCanonicalMapping
        return normalized.unicodeScalars.compactMap { scalar in
            let value = scalar.value
            switch value {
            case 0x0a, 0x0d, 0x85, 0x2028, 0x2029: return 0xff0d // X11 XK_Return
            case 0x09: return 0xff09 // X11 XK_Tab
            case 0..<0x20, 0x7f...0x9f: return nil
            case 0x20...0xff: return value
            default: return 0x0100_0000 | value
            }
        }
    }

    private static func textKeysyms(_ text: String) -> [UInt32]? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .precomposedStringWithCanonicalMapping
        var keysyms: [UInt32] = []
        for scalar in normalized.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x09, 0x0a, 0x0d, 0x85, 0x2028, 0x2029:
                // Dictation inserts text; only an explicit Up hold submits it.
                // Literal Tab/Return keystrokes could focus or execute a form.
                keysyms.append(0x20)
            case 0..<0x20, 0x7f...0x9f:
                // Validate the whole payload before inserting any part of it.
                return nil
            case 0x20...0xff:
                keysyms.append(value)
            default:
                // RFB uses X11 keysyms, whose Unicode range is U+0100 and
                // above with bit 24 set; a bare scalar means another key.
                keysyms.append(0x0100_0000 | value)
            }
        }
        return keysyms
    }
}
