import AppKit
// RoyalVNCKit predates Swift 6 strict concurrency; `@preconcurrency` keeps its
// non-Sendable types (VNCConnection/VNCFramebuffer/…) from tripping the actor
// checks when we bridge its delegate callbacks back onto the main actor.
@preconcurrency import RoyalVNCKit

/// Hosts RoyalVNCKit's ready-made macOS framebuffer view (`VNCCAFramebufferView`,
/// which renders the remote screen and forwards keyboard/mouse) for a session
/// owned by `RemoteDesktopSessionManager`.
///
/// This view owns *no* connection. Mounting it builds a framebuffer view over
/// the session's existing framebuffer and unmounting tears only that view down,
/// so switching groups costs a view rebuild rather than a reconnect and a second
/// trip through authentication.
@MainActor
final class RemoteDesktopViewer: NSView {
    private let coordinator = Coordinator()
    private let framebufferContainer = RemoteFramebufferContainerView()

    init(session: RemoteDesktopSession, framebufferGeneration: Int, onActivate: @escaping () -> Void = {}) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        framebufferContainer.frame = bounds
        framebufferContainer.autoresizingMask = [.width, .height]
        framebufferContainer.onActivate = onActivate
        framebufferContainer.session = session
        addSubview(framebufferContainer)
        coordinator.attach(to: framebufferContainer, session: session)
        coordinator.sync(generation: framebufferGeneration)
    }

    required init?(coder: NSCoder) { nil }

    func update(generation: Int, onActivate: @escaping () -> Void) {
        framebufferContainer.onActivate = onActivate
        coordinator.sync(generation: generation)
    }

    func detach() {
        if let responder = window?.firstResponder as? NSView,
           responder === self || responder.isDescendant(of: self) {
            window?.makeFirstResponder(nil)
        }
        coordinator.detach()
    }

    isolated deinit { coordinator.detach() }

    @MainActor
    final class Coordinator {
        private weak var container: NSView?
        private var session: RemoteDesktopSession?
        private var framebufferView: VNCCAFramebufferView?
        private var installedGeneration: Int?

        func attach(to container: NSView, session: RemoteDesktopSession) {
            self.container = container
            self.session = session
        }

        /// Rebuild the framebuffer view when the session's framebuffer changes
        /// identity, and drop it when the session has none.
        func sync(generation: Int) {
            guard let session, let container else { return }

            guard let framebuffer = session.framebuffer,
                  let connection = session.activeConnection,
                  let connectionDelegate = session.connectionDelegate else {
                removeFramebufferView()
                return
            }

            guard framebufferView == nil || installedGeneration != generation else { return }

            removeFramebufferView()

            let view = VNCCAFramebufferView(
                frame: container.bounds,
                framebuffer: framebuffer,
                connection: connection,
                connectionDelegate: connectionDelegate
            )
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            (container as? RemoteFramebufferContainerView)?.framebufferView = view
            framebufferView = view
            installedGeneration = generation
            // VNCCAFramebufferView takes focus on mouse-down. Mounting another
            // screen in a group must not steal input from the current machine.
        }

        func detach() {
            removeFramebufferView()
            session = nil
            container = nil
        }

        private func removeFramebufferView() {
            guard let framebufferView else { return }
            (container as? RemoteFramebufferContainerView)?.framebufferView = nil
            // `VNCCAFramebufferView.init` installs itself as the connection's
            // delegate and forwards through a weak reference. Hand the session's
            // relay back *before* this view dies, or the connection's weak
            // delegate goes nil and every status callback stops arriving.
            session?.restoreConnectionDelegate()
            framebufferView.removeFromSuperview()
            self.framebufferView = nil
            installedGeneration = nil
        }
    }
}

/// Observe which computer receives a mouse-down without installing a gesture
/// recognizer or intercepting the click. RoyalVNCKit still receives the exact
/// hit view and retains responsibility for remote mouse input and keyboard focus.
@MainActor
private final class RemoteFramebufferContainerView: NSView {
    var onActivate: () -> Void = {}
    weak var framebufferView: NSView?
    weak var session: RemoteDesktopSession?

    /// Runs before RoyalVNCKit forwards the shortcut. With "Share clipboard"
    /// on, ⌘V types the Mac clipboard: Apple Screen Sharing ignores the RFB
    /// cut-text RoyalVNCKit sends, so a forwarded ⌘V would only ever paste the
    /// remote's own clipboard.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let framebufferView, let session, event.type == .keyDown,
           window?.firstResponder === framebufferView,
           event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
           VNCPreferences.isClipboardRedirectionEnabled(id: session.connectionID) {
            let pasteboard = NSPasteboard.general
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c", "x":
                session.noteRemoteCopy(localChangeCount: pasteboard.changeCount)
            case "v":
                // Device-dependent flag bits say which Command key is held
                // (NX_DEVICELCMDKEYMASK / NX_DEVICERCMDKEYMASK), matching the
                // key RoyalVNCKit already pressed on the remote.
                let flags = event.modifierFlags.rawValue
                var held: [UInt32] = []
                if flags & 0x08 != 0 { held.append(VNCKeyCode.command.rawValue) }
                if flags & 0x10 != 0 { held.append(VNCKeyCode.rightCommand.rawValue) }
                switch session.pasteText(pasteboard.string(forType: .string),
                                         localChangeCount: pasteboard.changeCount, heldModifiers: held) {
                case .typed: return true
                case .rejected: NSSound.beep(); return true
                case .forwardToRemote: break
                }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        guard let target, let framebufferView,
              target === framebufferView || target.isDescendant(of: framebufferView),
              let event = NSApp?.currentEvent, let window, event.window === window,
              event.type == .leftMouseDown || event.type == .rightMouseDown
                || event.type == .otherMouseDown else { return target }
        onActivate()
        return target
    }
}
