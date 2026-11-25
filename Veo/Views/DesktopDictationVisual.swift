import AppKit
import SwiftUI

struct DesktopDictationVisual: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let dictation: DesktopDictation
    let draft: DesktopDictationDraft
    let fontSize: CGFloat
    let maxHeight: CGFloat
    let cancel: () -> Void

    @State private var reveal = DesktopDictationReveal()
    @State private var previewUpdate: Task<Void, Never>?

    var body: some View {
        TimelineView(.periodic(from: dictation.started, by: 1)) { timeline in
            let elapsed = max(0, Int(timeline.date.timeIntervalSince(dictation.started)))
            let status = switch dictation.phase {
            case .preparing: "Starting…"
            case .listening: "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
            case .transcribing: "thinking"
            case .revealing, .idle: ""
            }
            HStack(alignment: .top, spacing: 12) {
                preview
                HStack(spacing: 6) {
                    if !status.isEmpty {
                        Circle().fill(.primary).frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(status).monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityLabel(dictation.phase == .listening ? "Listening, \(elapsed) seconds" : status)
                    }
                    Button(action: cancel) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 19, height: 19)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Cancel dictation")
                    .accessibilityLabel("Cancel dictation")
                }
                .font(.system(size: 10.5))
                .padding(.trailing, 2)
                .frame(width: 78, alignment: .trailing)
            }
            .padding(.leading, 5)
            .padding(.top, 8)
        }
        .padding(.bottom, 29)
        .frame(minHeight: 104, alignment: .topLeading)
        .overlay {
            if !reduceMotion {
                GeometryReader { geometry in
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { time in
                        Canvas { context, size in
                            drawParticles(context, size: size, textWidth: max(1, size.width - 95), at: time.date)
                        }
                    }
                    .frame(height: geometry.size.height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onChange(of: dictation.transcript, initial: true) { _, _ in
            if reduceMotion || dictation.isBatch || dictation.phase == .revealing {
                previewUpdate?.cancel()
                previewUpdate = nil
                presentLatestTranscript()
            } else if previewUpdate == nil {
                previewUpdate = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(140)) }
                    catch { return }
                    previewUpdate = nil
                    presentLatestTranscript()
                }
            }
        }
        .onDisappear { previewUpdate?.cancel() }
        .task(id: dictation.phase) {
            guard dictation.phase == .revealing else { return }
            previewUpdate?.cancel()
            previewUpdate = nil
            presentLatestTranscript()
            if !reduceMotion {
                let remaining = reveal.text == dictation.transcript
                    ? reveal.remaining(after: Date()) : (dictation.isBatch ? 0.30 : 0.54)
                do { try await Task.sleep(for: .seconds(max(0.28, remaining))) }
                catch { return }
            }
            dictation.commitResult()
        }
    }

    private func presentLatestTranscript() {
        guard reveal.text != dictation.transcript else { return }
        reveal = DesktopDictationReveal(previous: reveal.text, next: dictation.transcript, batch: dictation.isBatch)
    }

    private var preview: some View {
        let spoken = reveal.text
        let value = spoken.isEmpty ? DesktopInlineContext.displayText(draft.text)
            : draft.inserting(spoken, forDisplay: true).text
        return ScrollView {
            if value.isEmpty {
                Text(dictation.phase == .transcribing ? "" : "Listening…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if spoken.isEmpty || reduceMotion {
                Text(value).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let parts = textLayers()
                Text(parts.settled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        DesktopDictationPhrase(text: parts.incoming, batch: reveal.batch)
                            .id(reveal.started)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(value)
            }
        }
        .font(.system(size: fontSize))
        .lineSpacing(2)
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: max(20, maxHeight - 21))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func textLayers() -> (settled: AttributedString, incoming: AttributedString) {
        let composed = draft.inserting(reveal.text, forDisplay: true)
        let source = composed.text as NSString
        let start = min(composed.end, composed.start + reveal.stableLength)
        let prefix = source.substring(to: start)
        let changed = source.substring(with: NSRange(location: start, length: composed.end - start))
        let suffix = source.substring(from: composed.end)
        func hidden(_ text: String) -> AttributedString {
            var result = AttributedString(text)
            result.foregroundColor = .clear
            return result
        }
        return (AttributedString(prefix) + hidden(changed) + AttributedString(suffix),
                hidden(prefix) + AttributedString(changed) + hidden(suffix))
    }

    private func drawParticles(_ context: GraphicsContext, size: CGSize, textWidth: CGFloat, at date: Date) {
        guard dictation.phase != .preparing else { return }
        let t = date.timeIntervalSince(dictation.started)
        let progress = reveal.progress(date)
        let x0 = size.width * 0.51
        let width = size.width * 0.80
        let bottom = size.height - 2
        let isListening = dictation.phase == .listening
        let finishing = dictation.phase == .revealing
            ? max(0, 1 - date.timeIntervalSince(dictation.revealStarted) / 0.28) : 1
        let level = isListening ? dictation.level.read() : 0.11 + 0.045 * sin(t * 3)
        let pitch: CGFloat = 4.8
        let columns = max(2, Int(width / pitch))
        var halo = Path()
        var solid = Path()
        var faint = Path()

        for column in 0..<columns {
            let fraction = Double(column) / Double(max(1, columns - 1))
            let x = x0 + (fraction - 0.5) * width
            let envelope = exp(-pow((fraction - 0.5 - sin(t * 5) * 0.036) / 0.19, 2))
            let ripple = 0.72 + 0.18 * sin(fraction * 37 - t * 11) + 0.11 * cos(fraction * 91 + t * 13)
            let height = (2.5 + (4 + 58 * level) * envelope * ripple) * finishing
            for row in 0..<Int(ceil(height / pitch)) {
                let seed = Double(column * 31 + row * 79)
                let sparkle = 0.5 + 0.5 * sin(seed * 1.773 + t * 3.4)
                let coverage = min(1, max(0, (height - Double(row) * pitch) / pitch))
                let radius = (0.46 + 1.48 * pow(sparkle, 4)) * sqrt(coverage)
                let point = CGPoint(x: x, y: bottom - Double(row) * pitch)
                if sin(seed * 6.71) > 0.28 {
                    solid.addEllipse(in: dot(point, radius))
                    halo.addEllipse(in: dot(point, radius * 2.10))
                } else {
                    faint.addEllipse(in: dot(point, radius * 0.68))
                }
            }
        }

        var tails = Path()
        if !reveal.batch, !reveal.text.isEmpty, progress < 1 {
            let inserted = draft.inserting(reveal.text, forDisplay: true)
            let start = min(inserted.end, inserted.start + reveal.stableLength)
            let targets = reveal.glyphTargets(text: inserted.text, start: start, end: inserted.end, width: textWidth, fontSize: fontSize)
            let offset = max(0, (targets.last?.y ?? 0) - maxHeight + fontSize)
            for (i, target) in targets.enumerated() {
                let seed = Double(i)
                let delay = Double(i) / Double(max(1, targets.count)) * 0.26
                let raw = (progress - delay) / 0.54
                guard raw >= 0 && raw < 1.23 else { continue }
                let end = CGPoint(x: target.x + 5, y: max(8, target.y + 8 - offset))
                let start = CGPoint(x: x0 + sin(seed * 2.12) * width * 0.11, y: bottom - 13 - level * 33 - cos(seed) * 8)
                let point = flight(from: start, to: end, progress: min(1, raw), seed: seed)
                if raw < 1.05 {
                    tails.move(to: flight(from: start, to: end, progress: max(0, raw - 0.12), seed: seed))
                    tails.addLine(to: point)
                }
                let radius = 0.66 + 0.45 * (sin(seed * 3.7) * 0.5 + 0.5)
                solid.addEllipse(in: dot(point, radius))
                halo.addEllipse(in: dot(point, radius * 2.5))
            }
        }

        context.fill(halo, with: .color(.primary.opacity(0.09 * finishing)))
        context.stroke(tails, with: .color(.primary.opacity(0.24)), lineWidth: 0.55)
        context.fill(faint, with: .color(.primary.opacity(0.29 * finishing)))
        context.fill(solid, with: .color(.primary.opacity(0.88 * max(finishing, 0.1))))
    }

    private func flight(from start: CGPoint, to end: CGPoint, progress: Double, seed: Double) -> CGPoint {
        let p = progress, q = 1 - p
        let first = CGPoint(x: start.x + sin(seed) * 13, y: start.y + (end.y - start.y) * 0.72)
        let second = CGPoint(x: end.x + (start.x - end.x) * 0.30, y: end.y - 4 + cos(seed) * 6)
        return CGPoint(x: q * q * q * start.x + 3 * q * q * p * first.x + 3 * q * p * p * second.x + p * p * p * end.x,
                       y: q * q * q * start.y + 3 * q * q * p * first.y + 3 * q * p * p * second.y + p * p * p * end.y)
    }

    private func dot(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

private struct DesktopDictationPhrase: View {
    let text: AttributedString
    let batch: Bool
    @State private var visible = false

    var body: some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(visible ? 1 : 0)
            .offset(y: !visible && batch ? 3 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: batch ? 0.28 : 0.25).delay(batch ? 0 : 0.14)) {
                    visible = true
                }
            }
    }
}

private final class DesktopDictationReveal {
    let started = Date()
    let text: String
    let stableLength: Int
    let batch: Bool
    private var cachedWidth: CGFloat?
    private var cachedTargets: [CGPoint] = []

    init(previous: String = "", next: String = "", batch: Bool = false) {
        self.batch = batch
        text = next
        stableLength = batch ? 0 : zip(previous, next).prefix(while: { $0 == $1 })
            .reduce(0) { $0 + String($1.0).utf16.count }
    }

    func progress(_ date: Date) -> Double {
        let elapsed = min(1, max(0, date.timeIntervalSince(started) / duration))
        return batch ? 1 - pow(1 - elapsed, 2) : elapsed
    }

    private var duration: Double { batch ? 0.29 : 0.54 }

    func remaining(after date: Date) -> Double { max(0, duration - date.timeIntervalSince(started)) }

    func glyphTargets(text: String, start: Int, end: Int, width: CGFloat, fontSize: CGFloat) -> [CGPoint] {
        if cachedWidth == width { return cachedTargets }
        cachedWidth = width
        guard end > start else { cachedTargets = []; return [] }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let storage = NSTextStorage(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph, .foregroundColor: NSColor.white
        ])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: start, length: end - start), actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container).integral
        guard bounds.width > 0, bounds.height > 0, bounds.width < 4096, bounds.height < 4096 else {
            cachedTargets = []
            return []
        }

        // Render just the incoming glyphs to a mask so the particles land on actual letter strokes.
        let w = Int(bounds.width), h = Int(bounds.height)
        let targets = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: w * h) { mask -> [CGPoint] in
            mask.initialize(repeating: 0)
            guard let bitmap = CGContext(data: mask.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
            bitmap.translateBy(x: -bounds.minX, y: bounds.maxY)
            bitmap.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
            manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            bitmap.flush()
            NSGraphicsContext.restoreGraphicsState()
            var points: [CGPoint] = []
            for x in stride(from: 0, to: w, by: 2) {
                for y in stride(from: x % 3, to: h, by: 3) where mask[y * w + x] > 75 {
                    points.append(CGPoint(x: bounds.minX + CGFloat(x), y: bounds.minY + CGFloat(y)))
                }
            }
            let step = max(1, Int(ceil(Double(points.count) / 105)))
            return stride(from: 0, to: points.count, by: step).map { points[$0] }
        }
        cachedTargets = targets
        return targets
    }
}
