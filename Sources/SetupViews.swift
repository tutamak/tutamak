import AppKit
import SwiftUI

// The setup speaks macOS: system type and colors, rows like System Settings' with a colored
// tile each, Liquid Glass buttons, and SF Symbols' own transitions when a state
// changes. Color means something (a row's kind, a state); nothing is decoration.

// MARK: Root

struct SetupView: View {
    let model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                StepView(model: model)
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.985)),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Footer(model: model)
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .ignoresSafeArea()
        .environment(\.artTime, model.artTime)
        .animation(.smooth(duration: 0.28), value: model.step)
    }
}

private struct ArtTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// Holds animations at a fixed moment (captures).
    var artTime: Double? {
        get { self[ArtTimeKey.self] }
        set { self[ArtTimeKey.self] = newValue }
    }
}

private struct StepView: View {
    let model: SetupModel

    var body: some View {
        switch model.step {
        case .permission: PermissionStep(model: model)
        case .systemGestures: GesturesStep(model: model)
        case .practice: ChooseStep(model: model)
        case .grid: GridStep(model: model)
        case .done: DoneStep(model: model)
        }
    }
}

// MARK: Steps

private struct PermissionStep: View {
    let model: SetupModel

    var body: some View {
        let granted = model.status.accessibilityGranted
        StepLayout(
            title: granted ? "Tutamak can move windows" : "Let Tutamak move windows",
            text: "macOS lets an app move other apps' windows only with Accessibility access. Tutamak uses it for the window under the pointer, nothing else."
        ) {
            AppIcon()
        } content: {
            Card {
                Row(symbol: "accessibility", tint: .blue, title: "Accessibility",
                    detail: granted ? "Allowed" : model.guiding ? "Drag Tutamak into the list in System Settings" : "Not allowed yet") {
                    StateMark(state: granted ? .done : model.guiding ? .working : .todo)
                }
            }
        }
    }
}

private struct GesturesStep: View {
    let model: SetupModel

    var body: some View {
        let on = model.status.fourFingerGesturesOn
        let three = model.status.threeFinger
        StepLayout(
            title: on ? "Free up four fingers" : "Four fingers are free",
            text: "macOS also uses four-finger swipes, for Mission Control and switching desktops. While they are on, they fire together with Tutamak's gestures."
        ) {
            SymbolBadge(symbol: "hand.raised.fingers.spread")
        } content: {
            Card {
                Row(symbol: "hand.raised.fingers.spread", tint: .orange, title: "Four-finger swipes and pinch",
                    detail: on ? "On in macOS"
                        : model.status.gesturesBackupExists ? "Off; the earlier settings can be restored in Settings" : "Off in macOS") {
                    StateMark(state: on ? (model.busy ? .working : .todo) : .done)
                }
                Row(symbol: "hand.point.up.left", tint: .gray, title: "Three-finger gestures",
                    detail: threeFingerDetail(three)) {
                    Text("Unchanged").font(.callout).foregroundStyle(.secondary)
                }
                if model.status.missionControlNeedsFlicks {
                    Row(symbol: "rectangle.3.group", tint: .indigo, title: "Flick up for Mission Control",
                        detail: "Tutamak's own: up for Mission Control, down for App Exposé") {
                        Toggle("", isOn: Binding(get: { model.bool("verticalFlicks") },
                                                 set: { model.setBool("verticalFlicks", $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            }
            if let failure = model.failure {
                Note(text: failure, symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else if !on {
                Note(text: "If a four-finger swipe still switches desktops, log out and back in.", symbol: "info.circle")
            }
        }
    }

    private func threeFingerDetail(_ t: ThreeFingerGestures) -> String {
        switch (t.swipesBetweenDesktops, t.missionControl) {
        case (true, true): "Desktops and Mission Control stay on three fingers"
        case (true, false): "Switching desktops stays on three fingers"
        case (false, true): "Mission Control stays on three fingers"
        default: "None are on"
        }
    }
}

/// The gestures Tutamak recognizes, shown and tried out. On the stage above the rows the gestures
/// play in turn, and the one under the pointer plays from its start, as in System Settings'
/// Trackpad pane; as soon as fingers touch the trackpad the stage shows them instead, live, with
/// the window responding. Each gesture performed gets a checkmark. Meanwhile nothing outside the
/// setup moves.
private struct ChooseStep: View {
    let model: SetupModel
    @State private var hovered: GestureDemo?
    @State private var hoverStart = Date()
    /// Eases the live fingers and window between display frames; kept across redraws.
    @State private var smoother = LiveSmoother()
    @Environment(\.artTime) private var artTime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let demos: [GestureDemo] = [.slide, .pinch, .tap, .flick]
    /// How long after the last touch a touch still wins over a pointed-at row.
    static let liveHold = 0.4

    /// Fingers have touched since this step opened.
    private var hasPracticed: Bool { model.feed.state.lastTouch.isFinite }

    var body: some View {
        StepLayout(
            title: "Try your gestures",
            text: "Put four fingers on the trackpad and try each one. Windows stay put while you practice.",
            pictureHeight: 150
        ) {
            stage
        } content: {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                // Once the practice has begun, a row is lit only while it is pointed at.
                let active: GestureDemo? = hasPracticed ? hovered : playing(at: context.date).demo
                Card {
                    Row(symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .blue, title: "Slide to move",
                        detail: "Let go at a screen edge to snap", highlighted: active == .slide,
                        done: model.practiced.contains(.slide)) {
                        Text("Always").font(.callout).foregroundStyle(.secondary)
                    }
                    .onHover { hover(.slide, $0) }
                    toggleRow(.pinch, "arrow.up.left.and.arrow.down.right", .green, "Pinch to resize",
                              "The pointer's place in the window picks the edges", key: "pinchToResize", active: active)
                    toggleRow(.tap, "arrow.up.backward.and.arrow.down.forward.rectangle", .purple, "Tap to maximize",
                              "Tap again to restore", key: "tapToMaximize", active: active)
                    toggleRow(.flick, "rectangle.on.rectangle.angled", .teal, "Flick to switch desktops",
                              "A quick sideways flick as the fingers land", key: "swipeToSwitch", active: active)
                }
            }
        }
    }

    @ViewBuilder private var stage: some View {
        if let artTime {
            let now = playing(at: Date(timeIntervalSinceReferenceDate: artTime))
            GestureStage(frame: .demo(now.demo, at: now.time))
        } else if reduceMotion {
            let demo = hovered ?? .slide
            GestureStage(frame: .demo(demo, at: demo.stillTime))
        } else {
            TimelineView(.animation) { context in
                let live = model.feed.state
                let uptime = ProcessInfo.processInfo.systemUptime
                // Once fingers have touched, the stage stays theirs: the window where they left
                // it, and no demo coming back on its own after a lift, which pulled the eye away.
                // A touch wins over the pointer resting on a row; between touches a pointed-at row
                // plays its demo, and the stage returns to the practice when the pointer leaves.
                let touching = uptime - live.lastTouch < Self.liveHold
                if touching || (hovered == nil && live.lastTouch.isFinite) {
                    GestureStage(frame: smoother.frame(for: live, now: uptime))
                } else {
                    let now = playing(at: context.date)
                    GestureStage(frame: .demo(now.demo, at: now.time))
                }
            }
        }
    }

    /// The demo on the stage and how far into it: the hovered one from its start, else the
    /// four in turn (each loop ends where the next begins).
    private func playing(at date: Date) -> (demo: GestureDemo, time: Double) {
        if let hovered { return (hovered, date.timeIntervalSince(hoverStart)) }
        let cycle = Self.demos.map(\.period).reduce(0, +)
        var t = (artTime ?? date.timeIntervalSinceReferenceDate).truncatingRemainder(dividingBy: cycle)
        for demo in Self.demos {
            if t < demo.period { return (demo, t) }
            t -= demo.period
        }
        return (.slide, 0)
    }

    private func hover(_ demo: GestureDemo, _ inside: Bool) {
        if inside {
            if hovered != demo { hoverStart = Date() }
            hovered = demo
        } else if hovered == demo {
            hovered = nil
        }
    }

    private func toggleRow(_ demo: GestureDemo, _ symbol: String, _ tint: Color, _ title: String, _ detail: String,
                           key: String, active: GestureDemo?) -> some View {
        let done = model.practiced.contains(demo) || (demo == .flick && model.practiced.contains(.flickUp))
        return Row(symbol: symbol, tint: tint, title: title, detail: detail, highlighted: active == demo, done: done) {
            Toggle("", isOn: Binding(get: { model.bool(key) }, set: { model.setBool(key, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .onHover { hover(demo, $0) }
    }
}

private struct GridStep: View {
    let model: SetupModel

    var body: some View {
        StepLayout(
            title: "Snap to a grid",
            text: "While you drag, the screen can show a grid; let go over a zone and the window takes it. Screen edges snap either way."
        ) {
            SymbolBadge(symbol: "square.grid.3x2")
        } content: {
            Card {
                Row(symbol: "square.grid.3x2", tint: .blue, title: "Snap grid",
                    detail: "Auto picks 3 × 2 on wide displays") {
                    Picker("", selection: Binding(get: { model.string("snapGrid") },
                                                  set: { model.setString("snapGrid", $0) })) {
                        ForEach(GridChoice.titled, id: \.raw) { Text($0.title).tag($0.raw) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Row(symbol: "rectangle.righthalf.inset.filled", tint: .gray, title: "Edge resistance",
                    detail: "Window edges stick to display edges for a moment") {
                    Toggle("", isOn: Binding(get: { model.bool("edgeResistance") },
                                             set: { model.setBool("edgeResistance", $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }
}

private struct DoneStep: View {
    let model: SetupModel

    var body: some View {
        StepLayout(
            title: "You're set",
            text: "Tutamak lives in the menu bar. Its menu opens Settings, and this assistant is there too, under Setup Assistant."
        ) {
            AppIcon()
        } content: {
            Card {
                Row(symbol: "power", tint: .gray, title: "Open at login", detail: "Start Tutamak when you log in") {
                    Toggle("", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }
}

// MARK: Layout

/// A step: its picture, title and a sentence, centered; then its rows.
private struct StepLayout<Picture: View, Content: View>: View {
    let title: String
    let text: String
    var pictureHeight: CGFloat = 76
    @ViewBuilder let picture: Picture
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            picture
                .frame(height: pictureHeight)
                .padding(.horizontal, 28)
                .padding(.top, 10)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .contentTransition(.opacity)
                .animation(.smooth, value: title)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(spacing: 10) { content }
                .padding(.top, 22)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AppIcon: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 76, height: 76)
            .accessibilityHidden(true)
    }
}

/// A step's picture when it is not the app: its symbol, large and quiet.
private struct SymbolBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 64, height: 64)
            .background(Circle().fill(.quinary))
            .accessibilityHidden(true)
    }
}

/// Rows in one rounded group, with a hairline between them, as in System Settings.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        _VariadicView.Tree(Layout()) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quinary))
    }

    private struct Layout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    if child.id != children.first?.id {
                        Divider().padding(.leading, 50)
                    }
                    child
                }
            }
        }
    }
}

/// A row: a colored tile with a white symbol, a title and a line under it, and its control.
private struct Row<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    /// The row whose gesture is playing above.
    var highlighted = false
    /// Tried in the practice: a checkmark beside the title.
    var done = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: done)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(.smooth, value: detail)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(highlighted ? 0.06 : 0))
            .padding(3))
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.25), value: highlighted)
    }
}

/// Where a row stands: to do, in progress, done; done arrives with a bounce.
private struct StateMark: View {
    enum State { case todo, working, done }
    let state: State

    var body: some View {
        ZStack {
            switch state {
            case .working:
                ProgressView().controlSize(.small)
            case .todo, .done:
                Image(systemName: state == .done ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 18))
                    .foregroundStyle(state == .done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .symbolEffect(.bounce, value: state == .done)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct Note: View {
    let text: String
    var symbol = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

// MARK: Footer

private struct Footer: View {
    let model: SetupModel

    var body: some View {
        HStack(spacing: 10) {
            PageDots(current: model.step)
            Spacer(minLength: 0)
            if model.showsBack {
                Button("Back") { model.back() }
                    .secondaryStyle()
            }
            if model.showsSkip {
                Button("Not Now") { model.skip() }
                    .secondaryStyle()
            }
            Button {
                model.runPrimary()
            } label: {
                Text(model.primary.title)
                    .frame(minWidth: 96)
            }
            .primaryStyle()
            .keyboardShortcut(.defaultAction)
            .disabled(model.busy || model.guiding)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { model.primaryButtonFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in model.primaryButtonFrame = frame }
            })
        }
        .controlSize(.large)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

private struct PageDots: View {
    let current: SetupStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(SetupStep.allCases.count)")
    }
}

/// Prominent Liquid Glass. In a window that is not active the prominent glass loses its tint and
/// its white title with it (seen on macOS 26.4), so there it is plain glass, whose title stays
/// readable.
private struct PrimaryStyle: ViewModifier {
    @Environment(\.controlActiveState) private var active

    func body(content: Content) -> some View {
        if active == .inactive { content.buttonStyle(.glass) } else { content.buttonStyle(.glassProminent) }
    }
}

private extension View {
    func primaryStyle() -> some View { modifier(PrimaryStyle()) }

    func secondaryStyle() -> some View { buttonStyle(.glass) }
}
