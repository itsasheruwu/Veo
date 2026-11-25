import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceTour {
    static let progressKey = "VeoDesktop.workspaceTour.v2"
    static let finished = 5

    static func initializeProgress(existingProfile: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: progressKey) == nil else { return }
        if let previous = defaults.object(forKey:"VeoDesktop.workspaceTour.v1") as? Int {
            defaults.set(previous >= 3 ? min(previous + 1, finished) : max(0, previous), forKey:progressKey)
        } else {defaults.set(existingProfile ? finished : 0, forKey: progressKey)}
    }
}

struct WorkspaceTourCommand: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var showWorkspaceTour: (() -> Void)? {
        get { self[WorkspaceTourCommand.self] }
        set { self[WorkspaceTourCommand.self] = newValue }
    }
}

struct DesktopOnboardingView: View {
    @Bindable var store: DesktopCodexStore
    @State private var showProviders = false
    @Binding var step: Int
    let pickFolder: () -> URL?
    let finish: (URL?) -> Void
    @AppStorage(DesktopAppearancePreferences.appearanceModeKey) private var appearance = DesktopAppearanceMode.dark.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var greeting = false
    @State private var ink: CGFloat = 0

    private let titles = ["Welcome to Veo.", "A home for every project.", "Make yourself at home.", "Choose your provider.", "Where shall we begin?"]
    private let details = [
        "A local workspace for Codex, from the first question to the final diff.",
        "Open a folder and Veo keeps its chats together. Return to a conversation and its working directory comes with it.",
        "Choose how your workspace looks. You can change it anytime in Appearance.",
        "Use Codex or connect another coding agent. You can switch providers beside the model picker in any chat.",
        "Choose a project folder to start a chat with Codex. You can also open Veo and pick a folder later."
    ]
    private var page: Int { min(max(step, 0), titles.count - 1) }
    private var lightPreview: Bool { appearance == "light" || (appearance == "system" && scheme == .light) }

    var body: some View {
        ZStack {
            VeoPrismView()
                .scaleEffect(greeting ? 1.07 : 1).blur(radius: greeting ? 15 : 0)
            LinearGradient(stops: [.init(color: .clear, location: 0.37),
                                   .init(color: Color.black.opacity(0.35), location: 0.68),
                                   .init(color: Color(red: 0.015, green: 0.025, blue: 0.075).opacity(0.84), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                HStack {
                    if page > 0 {
                        Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 15, height: 18) }
                            .accessibilityLabel("Back")
                    }
                    Spacer()
                    Button("Skip tour") { finish(nil) }.fixedSize()
                }
                .tourButtons().controlSize(.regular).font(.callout.weight(.medium)).tourControlGroup()
                .padding(.horizontal, 22).frame(height: 48)
                Spacer(minLength: 0)
                preview.id(page)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -9)))
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    HStack(spacing: 5) {
                        ForEach(0..<titles.count, id: \.self) { index in
                            Capsule().fill(.white.opacity(index == page ? 1 : 0.4))
                                .frame(width: page == index ? 21 : 5, height: 5)
                        }
                    }
                    .accessibilityElement().accessibilityLabel("Step \(page + 1) of \(titles.count)")
                    Text(titles[page]).font(.system(size: 30, weight: .bold)).tracking(-0.9)
                        .accessibilityAddTraits(.isHeader)
                    Text(details[page]).font(.system(size: 14)).foregroundStyle(.white.opacity(0.88))
                        .multilineTextAlignment(.center).frame(maxWidth: 380, minHeight: 41, alignment: .top)
                    if page == 2 {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(DesktopAppearanceMode.allCases) { mode in
                                Text(mode == .system ? "System" : mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 235)
                        .padding(3).tourPanel(radius: 9)
                    }
                    Button {
                        if page < titles.count - 1 { move(1) }
                        else if let url = pickFolder() { finish(url) }
                    } label: {
                        Text(["Take the tour", "Continue", "Continue", "Continue", "Choose a folder…"][page])
                            .font(.system(size: 14, weight: .semibold)).frame(minWidth: 160, minHeight: 33)
                    }
                    .tourButtons(primary: true).keyboardShortcut(.defaultAction)
                    if page == 4 {
                        Button("Open Veo without a folder") { finish(nil) }.tourButtons().font(.callout)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 15).frame(maxWidth: .infinity)
                .tourPanel(radius: 18, tint: .black.opacity(0.32))
                .padding(.horizontal, 18).padding(.bottom, 15)
            }
            .opacity(greeting ? 0 : 1).accessibilityHidden(greeting).disabled(greeting)
            if greeting {
                TourGreeting().trim(from: 0, to: ink)
                    .stroke(.white, style: .init(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: 210, height: 85).shadow(color: .white.opacity(0.5), radius: 8)
                    .accessibilityLabel("Hello")
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        .sheet(isPresented: $showProviders) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Providers").font(.title2.bold())
                    Spacer()
                    Button("Done") { showProviders = false }
                }
                ScrollView { DesktopProvidersView(store: store, onboarding: true).padding(2) }
            }.padding(18).frame(width: 422, height: 390).tourSheet()
        }
        .onExitCommand { if showProviders { showProviders = false } else { finish(nil) } }
        .task {
            guard page == 0, !reduceMotion else { return }
            greeting = true
            withAnimation(.easeInOut(duration: 1.35)) { ink = 1 }
            try? await Task.sleep(for: .seconds(1.7))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { greeting = false }
        }
    }

    private func move(_ offset: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) { step = page + offset }
    }

    @ViewBuilder private var preview: some View {
        if page == 0 {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 128, height: 128).shadow(color: .black.opacity(0.3), radius: 14, y: 5)
                .accessibilityHidden(true)
        } else if page == 3 {
            VStack(alignment: .leading, spacing: 12) {
                Text("Provider").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    DesktopProviderMark(id: store.activeAgent ?? (store.selectedModel?.isExternal == true ? nil : "codex"), size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.providerTitle).font(.system(size: 19, weight: .semibold))
                        Text(store.activeAgent == nil && store.providerTitle == "Codex" ? "Local Codex CLI" : "Connected provider")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") { showProviders = true }.tourButtons()
                        .accessibilityLabel("Providers · " + store.providerTitle)
                }
            }.padding(18).frame(width: 330, alignment: .leading)
                .tourPanel(radius: 17, tint: .black.opacity(0.28))
        } else if page == 4 {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.24), radius: 10, y: 5).accessibilityHidden(true)
        } else {
            let light = page == 2 && lightPreview
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.6)).frame(width: 6, height: 6) }
                    }
                    Label("New chat", systemImage: "square.and.pencil")
                    Label("Search", systemImage: "magnifyingglass")
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).padding(12).frame(width: 103, alignment: .leading)
                    .background(.primary.opacity(0.045))
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    if page == 1 {
                        Label("Veo", systemImage: "folder").font(.headline)
                        Label("Map the codebase", systemImage: "bubble.left")
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.blue.opacity(0.19), in: RoundedRectangle(cornerRadius: 6))
                        Label("Plan the first change", systemImage: "bubble.left").padding(.leading, 8)
                    } else {
                        Text("New chat").font(.system(size: 22, weight: .semibold))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Ask about this project…").foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }.padding(9).background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    }
                    Spacer(minLength: 0)
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 13)).frame(width: 350, height: 146)
                .foregroundStyle(light ? .black : .white)
                .tourPanel(radius: 16, tint: light ? .white.opacity(0.76) : .black.opacity(0.35))
                .environment(\.colorScheme, light ? .light : .dark).accessibilityHidden(true)
        }
    }
}

// A continuous pen stroke in a 210 × 85 coordinate space.
private struct TourGreeting: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 4, y: 67))
        func curve(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) {
            p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
        }
        curve(46, 13, 20, 68, 47, 29); curve(23, 69, 61, -9, 34, 45)
        curve(49, 46, 31, 54, 48, 32); curve(67, 57, 45, 61, 43, 82)
        curve(77, 45, 89, 43, 85, 32); curve(101, 53, 64, 66, 78, 81)
        curve(118, 15, 113, 35, 132, 8); curve(123, 58, 108, 14, 81, 93)
        curve(149, 12, 137, 39, 164, 0); curve(157, 55, 135, 16, 107, 98)
        curve(179, 44, 166, 39, 176, 39); curve(158, 64, 194, 53, 168, 80)
        curve(183, 52, 151, 53, 168, 34); curve(206, 44, 189, 59, 199, 50)
        return p.applying(CGAffineTransform(scaleX: rect.width / 210, y: rect.height / 85))
    }
}
