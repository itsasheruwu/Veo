import SwiftUI

struct DesktopImageGenerationCard: View {
    let item: DesktopTimelineItem
    let workspaceURL: URL?
    let isTurnRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var windowState
    @State private var visible = false

    private var running: Bool { isTurnRunning && item.isImageGenerationInProgress }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: running ? "photo.badge.plus" : "photo")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if running {
                generatingPreview
            } else if let artifact = item.artifacts.first {
                DesktopConceptImage(artifact: artifact, workspaceURL: workspaceURL, label: "Generated image")
            } else if !item.body.isEmpty {
                Text(item.body).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .trackingScrollVisibility { visible = $0 }
        .onDisappear { visible = false }
    }

    private var generatingPreview: some View {
        let paused = reduceMotion || !visible || windowState == .inactive
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * Double.pi / 4
            let progress: CGFloat = paused ? 0.5 : CGFloat((1 - cos(phase)) / 2)
            Canvas { drawing, size in
                drawGenerationPreview(&drawing, size: size, progress: progress)
            }
        }
        .aspectRatio(4 / 3 as CGFloat, contentMode: .fit)
        .background(Color(red: 0.03, green: 0.05, blue: 0.08), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func drawGenerationPreview(_ drawing: inout GraphicsContext, size: CGSize, progress: CGFloat) {
        var grid = Path()
        for x in stride(from: CGFloat(4), to: size.width, by: 8) {
            for y in stride(from: CGFloat(4), to: size.height, by: 8) {
                grid.addEllipse(in: CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7))
            }
        }
        drawing.fill(grid, with: .color(Color(red: 0.09, green: 0.25, blue: 0.39)))
        let centerX = size.width / 2 - 24 + progress * 56
        let centerY = size.height / 2 + 24 - 48 * progress
        let center = CGPoint(x: centerX, y: centerY)
        drawing.scaleBy(x: 1, y: 0.72)
        let stretch = CGAffineTransform(scaleX: 1, y: 1 / 0.72)
        drawing.opacity = 0.45 + 0.55 * Double(progress)
        drawing.fill(grid.applying(stretch), with: .radialGradient(
            Gradient(colors: [.cyan, .cyan.opacity(0.78), .clear]),
            center: center.applying(stretch), startRadius: 8, endRadius: size.width * 0.49
        ))
    }

    private var title: String {
        if running { return "Creating image" }
        if item.isImageGenerationInProgress { return "Image generation interrupted" }
        if item.status?.localizedCaseInsensitiveContains("cancel") == true { return "Image generation canceled" }
        return item.artifacts.isEmpty ? "Image generation failed" : "Generated image"
    }
}

struct DesktopGeneratedConcepts: View {
    let artifacts: [DesktopToolArtifact]
    let workspaceURL: URL?
    let addFeedback: ([DesktopToolArtifact], String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = Set<String>()
    @State private var comparing = false
    @State private var feedback = ""
    @State private var added = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Generated concepts").font(.subheadline.weight(.semibold))
                Spacer()
                Button(comparing ? "Show all concepts" : "Compare selected") { changeComparison(!comparing) }
                    .disabled(!comparing && selection.count < 2)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: comparing ? 215 : 152), alignment: .top)], spacing: 10) {
                ForEach(Array(artifacts.enumerated()).filter { !comparing || selection.contains($0.element.id) }, id: \.element.id) { index, artifact in
                    VStack(alignment: .leading, spacing: 6) {
                        DesktopConceptImage(artifact: artifact, workspaceURL: workspaceURL, label: "Concept \(index + 1)")
                        Toggle("Concept \(index + 1)", isOn: Binding(
                            get: { selection.contains(artifact.id) },
                            set: { selected in
                                if selected { selection.insert(artifact.id) } else { selection.remove(artifact.id) }
                                if selection.count < 2 && comparing { changeComparison(false) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selection.contains(artifact.id) ? Color.accentColor : Color.secondary.opacity(0.15)))
                    .transition(.opacity)
                }
            }

            Text("Feedback").font(.caption.weight(.semibold))
            TextEditor(text: $feedback)
                .font(.body)
                .frame(minHeight: 58, maxHeight: 100)
                .accessibilityLabel("Feedback")
                .onChange(of: feedback) { _, _ in added = false }
            HStack {
                Text(added ? "Added to draft" : "\(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add feedback to draft") {
                    let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                    addFeedback(artifacts.filter { selection.contains($0.id) }, note)
                    feedback = ""
                    added = true
                }
                .disabled(selection.isEmpty || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func changeComparison(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { comparing = value }
    }
}

struct DesktopConceptImage: View {
    let artifact: DesktopToolArtifact
    let workspaceURL: URL?
    let label: String
    @State private var preview = false

    private var descriptor: SafeLocalFileDescriptor? {
        guard artifact.kind == .localFile else { return nil }
        return try? SafeLocalFileDescriptor.inspect(path: artifact.source, declaredMIMEType: artifact.mimeType, workspaceURL: workspaceURL)
    }

    var body: some View {
        Button { preview = true } label: {
            previewImage(allowOutside: false)
                .frame(maxWidth: .infinity, minHeight: 82)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(label)")
        .sheet(isPresented: $preview) {
            VStack(spacing: 14) {
                Text(label).font(.headline)
                previewImage(allowOutside: true)
                Button("Done") { preview = false }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            .frame(minWidth: 370, minHeight: 180)
        }
    }

    @ViewBuilder private func previewImage(allowOutside: Bool) -> some View {
        if let descriptor, allowOutside || !descriptor.isOutsideWorkspace {
            SafeLocalImagePreview(descriptor: descriptor)
        } else if artifact.kind == .inlineImage {
            SafeInlineArtifactImage(artifact: artifact)
        } else {
            Label(descriptor?.isOutsideWorkspace == true ? "Open image outside workspace" : "Image unavailable", systemImage: "photo")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}


extension View {
    @ViewBuilder func trackingScrollVisibility(_ update: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onScrollVisibilityChange(threshold: 0.05, update)
        } else {
            onAppear { update(true) }.onDisappear { update(false) }
        }
    }
}
