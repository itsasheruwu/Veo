import AppKit
import SwiftUI

/// Owns the handoff so the tour and workspace occupy the same native window.
struct DesktopLaunchView: View {
    let store: DesktopCodexStore
    @ObservedObject var navigation: DesktopNavigationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(WorkspaceTour.progressKey) private var step = 0
    @State private var touring = UserDefaults.standard.integer(forKey: WorkspaceTour.progressKey) < WorkspaceTour.finished
    @State private var workspaceLoaded = UserDefaults.standard.integer(forKey: WorkspaceTour.progressKey) >= WorkspaceTour.finished
    @State private var revealing = false
    @State private var window: NSWindow?
    @State private var destination: NSRect?
    @State private var toolbarWasVisible = true

    var body: some View {
        Group {
            if workspaceLoaded {
                DesktopWorkspaceView(store: store, navigation: navigation, canPresentNotice: !touring)
                    .blur(radius: touring && !revealing && !reduceMotion ? 15 : 0)
                    .opacity(touring && !revealing ? 0 : 1)
                    .accessibilityHidden(touring).disabled(touring).allowsHitTesting(!touring)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .overlay {
            if touring {
                DesktopOnboardingView(store:store, step: $step, pickFolder: store.pickProjectFolder, finish: finish)
                    .scaleEffect(revealing && !reduceMotion ? 1.08 : 1)
                    .blur(radius: revealing && !reduceMotion ? 18 : 0)
                    .opacity(revealing ? 0 : 1)
                    .allowsHitTesting(!revealing)
            }
        }
        .frame(minWidth: touring ? 480 : 920, minHeight: touring ? 460 : 640)
        .background(TourWindowReader { attached in
            guard window !== attached else { return }
            window = attached
            attached.titlebarAppearsTransparent = true
            attached.titlebarSeparatorStyle = .none
            if touring { compact(attached, replay: false) }
        })
        .focusedSceneValue(\.showWorkspaceTour, touring ? nil : {
            guard let window else { return }
            step = 0
            touring = true
            // Let SwiftUI release the workspace minimum before resizing.
            Task { @MainActor in
                await Task.yield()
                if touring { compact(window, replay: true) }
            }
        })
    }

    private func compact(_ window: NSWindow, replay: Bool) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let work = screen.visibleFrame
        if replay, let toolbar = window.toolbar {
            toolbarWasVisible = toolbar.isVisible
            toolbar.isVisible = false
        }
        let frame = window.frame
        destination = replay || frame.width >= 920 ? frame : centered(
            NSSize(width: min(1440, work.width), height: min(900, work.height)), in: work)
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(centered(NSSize(width: 558, height: 548), in: destination ?? work), display: true)
    }

    private func centered(_ size: NSSize, in frame: NSRect) -> NSRect {
        NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height).integral
    }

    private func finish(_ folder: URL?) {
        guard touring, step < WorkspaceTour.finished else { return }
        workspaceLoaded = true
        step = WorkspaceTour.finished
        let window = self.window
        let target = destination
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(25))
            if let window, let target, let screen = window.screen, !window.styleMask.contains(.fullScreen) {
                let frame = window.constrainFrameRect(target, to: screen)
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = reduceMotion ? 0 : 0.72
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                }, completionHandler: nil)
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.72)) { revealing = true }
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(740)) }
            window?.toolbar?.isVisible = toolbarWasVisible
            touring = false
            revealing = false
            if let folder {
                navigation.showWorkspace()
                store.beginProjectChat(at: folder)
            }
        }
    }
}

private struct TourWindowReader: NSViewRepresentable {
    let attached: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reader { Reader(attached: attached) }
    func updateNSView(_ view: Reader, context: Context) { view.attached = attached }

    final class Reader: NSView {
        var attached: (NSWindow) -> Void
        init(attached: @escaping (NSWindow) -> Void) {
            self.attached = attached
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.attached(window) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
