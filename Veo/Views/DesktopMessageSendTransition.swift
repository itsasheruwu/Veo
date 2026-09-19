// Purpose: Carries a submitted draft from its composer geometry into its own timeline row.

import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class DesktopMessageSendTransition {
    enum Part: Hashable { case text, attachment(Int), attachmentViewport, bubble }
    enum Role { case composer, message(String?), none }
    static let coordinateSpace = "veo.message-send"
    static let animation = Animation.spring(response: 0.48, dampingFraction: 0.88)

    struct Flight: Identifiable {
        let payload: DesktopComposerPayload
        let sourceFrames: [Part: CGRect]
        let textImage: NSImage?
        let attachmentImages: [String: NSImage]
        let attachmentViewport: CGRect?
        var id: String { payload.id }
    }

    private(set) var flight: Flight?
    private(set) var destinationFrames: [Part: CGRect] = [:]
    private(set) var progress: CGFloat = 0
    @ObservationIgnored private var sourceFrames: [Part: CGRect] = [:]
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private var landingTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    var isPresenting: Bool { flight != nil }
    func presents(_ clientID: String?) -> Bool {
        guard let clientID else { return false }
        return flight?.id == clientID
    }

    func registerTextView(_ view: NSTextView) { textView = view }

    func record(_ frame: CGRect, part: Part, role: Role) {
        guard frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite else { return }
        switch role {
        case .composer:
            sourceFrames[part] = frame
        case .message(let clientID):
            guard presents(clientID), destinationFrames[part] != frame else { return }
            if progress == 0 {
                destinationFrames[part] = frame
                scheduleLanding()
            } else {
                withAnimation(Self.animation) { destinationFrames[part] = frame }
            }
        case .none: break
        }
    }

    /// Runs synchronously at acceptance, before the store clears the native editor.
    func begin(_ payload: DesktopComposerPayload) {
        cancel()
        var frames = sourceFrames.filter { part, _ in
            switch part {
            case .text: return !payload.trimmedText.isEmpty
            case .attachment(let index): return payload.attachments.indices.contains(index)
            case .attachmentViewport, .bubble: return false
            }
        }
        var textImage: NSImage?
        if !payload.trimmedText.isEmpty, let textView,
           let container = textView.textContainer, let layout = textView.layoutManager,
           let editorFrame = frames[.text] {
            layout.ensureLayout(for: container)
            let visible = textView.visibleRect
            let glyphs = layout.usedRect(for: container)
                .offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
                .intersection(visible)
            if !glyphs.isEmpty, let bitmap = textView.bitmapImageRepForCachingDisplay(in: glyphs) {
                textView.cacheDisplay(in: glyphs, to: bitmap)
                let image = NSImage(size: glyphs.size)
                image.addRepresentation(bitmap)
                textImage = image
                frames[.text] = CGRect(
                    x: editorFrame.minX + glyphs.minX - visible.minX,
                    y: editorFrame.minY + glyphs.minY - visible.minY,
                    width: glyphs.width, height: glyphs.height
                )
            }
        }
        guard !frames.isEmpty else { return }
        let attachmentViewport = sourceFrames[.attachmentViewport]
        let visibleBounds = frames.reduce(CGRect.null) { bounds, entry in
            if case .attachment = entry.key, let attachmentViewport {
                return bounds.union(entry.value.intersection(attachmentViewport))
            }
            return bounds.union(entry.value)
        }
        guard !visibleBounds.isNull else { return }
        frames[.bubble] = visibleBounds.insetBy(dx: -14, dy: -10)
        // Decode thumbnails once per send, never on an animation frame.
        var images: [String: NSImage] = [:]
        for attachment in payload.attachments where attachment.kind == .localImage {
            images[attachment.id] = NSImage(contentsOfFile: attachment.source)
        }
        flight = Flight(
            payload: payload, sourceFrames: frames, textImage: textImage,
            attachmentImages: images, attachmentViewport: attachmentViewport
        )
        let id = payload.id
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, self.flight?.id == id, self.progress == 0 else { return }
            self.cancel()
        }
    }

    private func scheduleLanding() {
        guard let flight, flight.sourceFrames.keys.allSatisfy({ destinationFrames[$0] != nil }) else { return }
        landingTask?.cancel()
        let id = flight.id
        landingTask = Task { @MainActor [weak self] in
            // Let the lazy timeline mount the row and finish its immediate scroll first.
            try? await Task.sleep(for: .milliseconds(32))
            guard !Task.isCancelled, let self, self.flight?.id == id else { return }
            self.expiryTask?.cancel()
            withAnimation(Self.animation) {
                self.progress = 1
            }
            // Keep the overlay alive for the complete spring, even if the first
            // message mounts in a transaction that suppresses insertion animation.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, self.flight?.id == id else { return }
            self.cancel()
        }
    }

    func cancel() {
        landingTask?.cancel()
        expiryTask?.cancel()
        landingTask = nil
        expiryTask = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flight = nil
            destinationFrames = [:]
            progress = 0
        }
    }
}

struct DesktopSendGeometry: ViewModifier {
    @Environment(DesktopMessageSendTransition.self) private var transition: DesktopMessageSendTransition?
    let part: DesktopMessageSendTransition.Part
    let role: DesktopMessageSendTransition.Role

    func body(content: Content) -> some View {
        if shouldMeasure {
            content.onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(DesktopMessageSendTransition.coordinateSpace))
            } action: { frame in
                transition?.record(frame, part: part, role: role)
            }
        } else {
            content
        }
    }

    private var shouldMeasure: Bool {
        guard let transition else { return false }
        switch role {
        case .composer: return true
        case .message(let id): return transition.presents(id)
        case .none: return false
        }
    }
}

struct DesktopMessageSendOverlay: View {
    let transition: DesktopMessageSendTransition
    var body: some View {
        if let flight = transition.flight {
            DesktopMessageSendFlightView(
                flight: flight, destination: transition.destinationFrames, progress: transition.progress
            )
            .id(flight.id)
            .transition(.identity)
            .animation(DesktopMessageSendTransition.animation, value: transition.progress)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct DesktopMessageSendFlightView: View, Animatable {
    let flight: DesktopMessageSendTransition.Flight
    let destination: [DesktopMessageSendTransition.Part: CGRect]
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            let bubble = frame(.bubble)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.065 * Double(amount)))
                .frame(width: bubble.width, height: bubble.height)
                .position(x: bubble.midX, y: bubble.midY)

            if !flight.payload.trimmedText.isEmpty {
                let text = frame(.text)
                ZStack(alignment: .topLeading) {
                    if let image = flight.textImage {
                        Image(nsImage: image).resizable()
                            .opacity(Double(1 - amount))
                    }
                    Text(flight.payload.trimmedText)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(flight.textImage == nil ? 1 : Double(amount))
                }
                .frame(width: text.width, height: text.height, alignment: .topLeading)
                .clipped()
                .position(x: text.midX, y: text.midY)
            }

            ZStack(alignment: .topLeading) {
                ForEach(Array(flight.payload.attachments.enumerated()), id: \.element.id) { index, attachment in
                    if flight.sourceFrames[.attachment(index)] != nil {
                        let rect = frame(.attachment(index))
                        DesktopAttachmentPreview(
                            attachment: attachment, onRemove: nil,
                            cachedImage: flight.attachmentImages[attachment.id]
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask {
                let viewport = attachmentClipFrame
                Rectangle().frame(width: viewport.width, height: viewport.height)
                    .position(x: viewport.midX, y: viewport.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var amount: CGFloat { min(max(progress, 0), 1) }
    private var attachmentClipFrame: CGRect {
        let source = flight.attachmentViewport ?? flight.sourceFrames[.bubble] ?? .zero
        let target = destination[.attachmentViewport] ?? destination[.bubble] ?? source
        return interpolate(source, target)
    }

    private func frame(_ part: DesktopMessageSendTransition.Part) -> CGRect {
        let source = flight.sourceFrames[part] ?? .zero
        let target = destination[part] ?? source
        return interpolate(source, target)
    }

    private func interpolate(_ source: CGRect, _ target: CGRect) -> CGRect {
        return CGRect(
            x: source.minX + (target.minX - source.minX) * progress,
            y: source.minY + (target.minY - source.minY) * progress,
            width: max(0, source.width + (target.width - source.width) * amount),
            height: max(0, source.height + (target.height - source.height) * amount)
        )
    }
}
