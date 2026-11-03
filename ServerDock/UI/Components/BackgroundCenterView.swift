import Combine
import SwiftUI

/// Transfer accent color: Apple blue matching monitor upload color, defined locally because Pal has no built-in blue.
private let transferBlue = Color(hex: 0x007AFF)

// Springy record insertion/removal using scale and opacity transitions.
private let popTransition: AnyTransition = .scale(scale: 0.82, anchor: .center).combined(with: .opacity)
private let popSpring: Animation = .spring(response: 0.34, dampingFraction: 0.56)

/// One-shot download fly-in event when no dialog is shown: mouse position to the bottom-left background button's reported center.
struct FlyEvent: Identifiable, Equatable {
    let id: UUID
    let from: CGPoint
}

/// Throw a file icon along an arc from `from` to `to`, shrinking/fading as it reaches the background button.
/// onAppear starts one animation; completion clears the event. No timer/polling remains after the animation.
struct FlyToCornerView: View {
    let from: CGPoint
    let to: CGPoint
    let onDone: () -> Void
    @State private var progress: CGFloat = 0
    private let duration = 0.62

    var body: some View {
        Image(lucideSymbol: "arrow.down.doc.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color(hex: 0x007AFF), in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .modifier(ArcFly(progress: progress, from: from, to: to))
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.timingCurve(0.36, 0, 0.2, 1, duration: duration)) { progress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { onDone() }
            }
    }
}

/// One animatable progress value (0->1) drives a quadratic Bezier arc, shrinking/fading near the end.
private struct ArcFly: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGPoint
    let to: CGPoint
    var animatableData: CGFloat { get { progress } set { progress = newValue } }

    func body(content: Content) -> some View {
        let p = point(progress)
        return content
            .scaleEffect(1 - 0.55 * progress)
            .opacity(progress < 0.8 ? 1 : Double(max(0, (1 - progress) / 0.2)))
            .position(p)
    }

    /// Place the control point above the endpoint midpoint to create an upward throw followed by a drop.
    private func point(_ t: CGFloat) -> CGPoint {
        let lift = max(90, abs(from.y - to.y) * 0.5)
        let ctrl = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - lift)
        let mt = 1 - t
        let x = mt * mt * from.x + 2 * mt * t * ctrl.x + t * t * to.x
        let y = mt * mt * from.y + 2 * mt * t * ctrl.y + t * t * to.y
        return CGPoint(x: x, y: y)
    }
}

/// Invisible watcher opens the background upload dialog when a name conflict needs confirmation, preventing a silent stall.
/// Observes UploadTask to stay alive, without visible content.
struct UploadAskWatcher: View {
    @ObservedObject var task: UploadTask
    let onNeedConfirm: () -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: task.pendingAsk?.id) { id in if id != nil { onNeedConfirm() } }
    }
}

/// Independent data source for the bottom-left button's progress ring.
///
/// Transfers sample overallSent at 10Hz; bridging every change into AppModel
/// would redraw the entire observing ContentView tree many times per second, as noted in forwardCancellables.
/// Subscribe to tasks separately and publish only when the integer percentage or presence of progress changes,
/// reducing 10Hz-per-task updates to one per percentage point and limiting redraws to the ring.
///
/// Aggregate all running/queued/paused upload/download progress by byte weight:
/// fraction = total sent / total bytes. Queued tasks contribute 0% and count in the denominator,
/// so adding a large pending file immediately lowers progress to reflect remaining work accurately.
/// Exclude unbounded persistent forwarding and extraction without byte progress. fraction=nil hides the ring when no measurable transfer exists.
@MainActor
final class BackgroundProgressModel: ObservableObject {
    @Published private(set) var fraction: Double?

    private let app = AppModel.shared
    private var appSub: AnyCancellable?
    private var taskSubs: [UUID: AnyCancellable] = [:]
    private var lastPercent: Int = -2   // Reserve -1 for no progress; initialize to -2 to force the first publication.

    init() {
        appSub = app.$transfers.sink { [weak self] tasks in self?.rewire(tasks) }
        rewire(app.transfers)
    }

    /// Rebuild task subscriptions when tasks enter/leave/are cleared.
    private func rewire(_ tasks: [UploadTask]) {
        let ids = Set(tasks.map(\.id))
        taskSubs = taskSubs.filter { ids.contains($0.key) }
        for t in tasks where taskSubs[t.id] == nil {
            // objectWillChange fires before mutation; read next run-loop turn to obtain updated values.
            taskSubs[t.id] = t.objectWillChange.sink { [weak self] in
                Task { @MainActor in self?.recompute() }
            }
        }
        recompute()
    }

    private func recompute() {
        var total: Int64 = 0, sent: Int64 = 0
        for t in app.transfers where t.phase == .running || t.phase == .paused || t.phase == .queued {
            total += t.totalBytes
            sent += min(t.overallSent, t.totalBytes)
        }
        let f: Double? = total > 0 ? min(1, Double(sent) / Double(total)) : nil
        let pct = f.map { Int($0 * 100) } ?? -1
        guard pct != lastPercent else { return }
        lastPercent = pct
        fraction = f
    }
}

/// Green center dot for running forwarding uses a self-reversing SwiftUI scale/opacity animation without a timer.
/// Mount/remove with hasRunningForward, leaving no idle overhead after forwarding stops.
private struct ForwardBreathingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(hex: 0x32D74B))                  // Running green.
            .frame(width: 3.5, height: 3.5)              // Dot size.
            .scaleEffect(on ? 1.0 : 0.85)
            .opacity(on ? 1.0 : 0.6)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Persistent bottom activity-bar Background Tasks button; active tasks show a badge, and clicking opens the unified center.
/// Overlay a thin progress ring for measurable transfers without affecting layout/button size.
struct BackgroundCenterButton: View {
    @ObservedObject var model: AppModel
    @StateObject private var progress = BackgroundProgressModel()
    @State private var open = false
    @State private var hover = false

    private static let side: CGFloat = 46
    private static let ringDiameter: CGFloat = 26   // Ring diameter stays below the 38pt button to fit the icon without appearing bulky.
    private static let ringWidth: CGFloat = 1.8

    var body: some View {
        // Badge counts only transfers/extraction. Persistent forwarding uses the green center pulse instead.
        let count = model.nonForwardActiveCount
        Button { open.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(lucideSymbol: "tray.full")
                    .font(.system(size: 16))
                    .foregroundStyle(open ? Pal.textBright : (hover ? Pal.text : Pal.subtext))
                    .frame(width: Self.side, height: Self.side)
                    .background(
                        open ? Pal.fill(0.11) : (hover ? Pal.fill(0.06) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .overlay { progressRing }
                    .overlay { if model.hasRunningForward { ForwardBreathingDot().offset(x: 0, y: 0.25) } }   // Running forwarding: green center pulse.
                    .background(GeometryReader { geo in        // Report the button's global center as the download fly-in destination.
                        Color.clear
                            .onAppear { report(geo) }
                            .onChange(of: geo.frame(in: .global)) { _ in report(geo) }
                    })
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                        .background(Pal.mauve, in: Capsule())
                        .overlay(Capsule().stroke(Pal.crust, lineWidth: 1.5))   // Separate the badge visually from the activity-bar background.
                        .offset(x: 4, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .help(String(localized: "Background Tasks"))
        .popover(isPresented: $open, arrowEdge: .trailing) {
            BackgroundCenterPanel(model: model, dismiss: { open = false })
        }
    }

    private func report(_ geo: GeometryProxy) {
        let f = geo.frame(in: .global)
        model.backgroundButtonCenter = CGPoint(x: f.midX, y: f.midY)
    }

    /// Circular ring with a dark track and rounded transfer-blue progress, advancing clockwise from the top.
    @ViewBuilder
    private var progressRing: some View {
        if let p = progress.fraction {
            ZStack {
                Circle().stroke(Pal.fill(0.10), lineWidth: Self.ringWidth)
                Circle()
                    .trim(from: 0, to: max(0.001, p))
                    .stroke(transferBlue, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
            }
            .rotationEffect(.degrees(-90))   // Circle trim starts at the right; rotate it to start at the top like a clock.
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)   // Smaller than the button and centered around the icon.
            .animation(.linear(duration: 0.18), value: p)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}

/// Unified background center groups active forwarding/transfers/extraction by host with inline management.
struct BackgroundCenterPanel: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            content
        }
        .frame(width: 360, height: 440)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(lucideSymbol: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.mauve)
                .frame(width: 26, height: 26)
                .background(Pal.mauve.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            Text("Background Tasks").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
            Spacer()
            let n = model.activeBackgroundCount
            if n > 0 {
                Text("\(n) in progress").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
            if model.hasFinishedBackground {
                Button { withAnimation(popSpring) { model.clearFinishedBackground() } } label: {
                    HStack(spacing: 4) {
                        Image(lucideSymbol: "trash").font(.system(size: 9))
                        Text("Clear Completed").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Pal.subtext)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Pal.fill(0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(String(localized: "Clear all completed and canceled tasks"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        // Keep ScrollView mounted so the last row finishes its exit animation; fade the empty state in as an overlay.
        ScrollView {
            BackgroundActivityList(model: model, dismiss: dismiss)
                .padding(.horizontal, 12).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if model.backgroundActivities.isEmpty {
                emptyState.transition(.opacity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(lucideSymbol: "tray")
                .font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text("No Background Tasks").font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("Port forwarding, uploads, downloads, extraction, and more are managed here.")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .multilineTextAlignment(.center).frame(maxWidth: 240)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Host-grouped activity list (shared by center and quit confirmation)

/// Group task rows by host; readOnly hides action buttons for quit confirmation while preserving task data.
struct BackgroundActivityList: View {
    @ObservedObject var model: AppModel
    var readOnly: Bool = false
    var includeFinished: Bool = true   // false lists only ongoing tasks for quit confirmation.
    var dismiss: () -> Void = {}

    // Use a named structure; Swift does not support tuple-member KeyPaths, so ForEach(id:) would fail to compile.
    private struct HostGroup: Identifiable {
        let id: String              // hostId or "__local__".
        let hostId: String?
        let items: [BackgroundActivity]
    }

    // Group in first-seen host order; stably place active tasks before finished ones while preserving each subset's order.
    private var groups: [HostGroup] {
        var order: [String] = []
        var map: [String: [BackgroundActivity]] = [:]
        for a in model.backgroundActivities {
            if !includeFinished && a.isFinished { continue }
            let key = a.hostId ?? "__local__"
            if map[key] == nil { order.append(key); map[key] = [] }
            map[key]?.append(a)
        }
        return order.map { key in
            let items = map[key] ?? []
            let sorted = items.filter { !$0.isFinished } + items.filter { $0.isFinished }
            return HostGroup(id: key, hostId: key == "__local__" ? nil : key, items: sorted)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                groupSection(group.hostId, group.items).transition(popTransition)
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ hostId: String?, _ items: [BackgroundActivity]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            hostHeader(hostId, fallback: items.first?.fallbackHostName ?? "")
            VStack(spacing: 7) {
                ForEach(items) { activity in
                    row(activity).transition(popTransition)
                }
            }
        }
    }

    @ViewBuilder
    private func hostHeader(_ hostId: String?, fallback: String) -> some View {
        HStack(spacing: 8) {
            if let id = hostId, let host = model.host(id) {
                HostLeadingIcon(host: host).scaleEffect(0.64).frame(width: 20, height: 20)
                Text(host.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
            } else {
                Image(lucideSymbol: "desktopcomputer").font(.system(size: 11)).foregroundStyle(Pal.overlay).frame(width: 20)
                Text(hostId == nil ? String(localized: "Local") : (fallback.isEmpty ? String(localized: "Unknown Host") : fallback))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func row(_ activity: BackgroundActivity) -> some View {
        switch activity.payload {
        case .forward(let rule, let manager):
            HubForwardRow(rule: rule, manager: manager, readOnly: readOnly,
                          onToggle: { model.toggleForward(rule) },
                          onManage: {
                              if let h = model.host(rule.hostId) { model.openForwardPanel(h) }
                              dismiss()
                          })
        case .transfer(let task):
            HubTransferRow(task: task, readOnly: readOnly,
                           onOpen: { model.focusedTransferId = task.id; dismiss() },
                           onClear: { withAnimation(popSpring) { model.removeTransfer(task.id) } })
        case .extract(let task):
            HubExtractRow(task: task, readOnly: readOnly,
                          onOpen: { model.showExtractDialog = true; dismiss() },
                          onClear: { withAnimation(popSpring) { model.clearExtract() } })
        }
    }
}

// MARK: - Custom quit confirmation

/// Custom quit confirmation:
/// With background tasks, show a prominent interruption warning and read-only task list.
/// Without tasks, show a compact quit confirmation.
/// Selecting Hide to menu bar when closing immediately persists that setting and changes confirmation from quitting to hiding.
struct QuitConfirmDialog: View {
    @ObservedObject var model: AppModel
    var forceMode: Bool = false    // Explicit menu-bar Quit ServerDock stops tasks and exits after confirmation, without a hide option or preference override.
    let onCancel: () -> Void
    let onHideToTray: () -> Void   // Checked: hide to the menu bar; the checkbox already updated the setting.
    let onConfirm: () -> Void       // Unchecked: quit.
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var theme = ThemeManager.shared

    private var hasTasks: Bool { model.hasRunningBackground }
    // Hide only in ordinary close mode when the preference is enabled; explicit full-quit mode always exits.
    private var hidesOnConfirm: Bool { !forceMode && settings.closeToTray }
    private var confirmTitle: String {
        if forceMode { return hasTasks ? String(localized: "Stop Tasks and Quit") : String(localized: "Quit") }
        return settings.closeToTray ? String(localized: "OK") : (hasTasks ? String(localized: "Close Tasks and Quit") : String(localized: "Quit"))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(theme.isDark ? 0.42 : 0.20).ignoresSafeArea()
                .onTapGesture(perform: onCancel)
            card
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if hasTasks {
                ScrollView {
                    BackgroundActivityList(model: model, readOnly: true, includeFinished: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }

            // Checking immediately persists Hide to menu bar when closing, keeping background tasks running.
            // Explicit menu-bar quit omits hiding because the user has chosen to terminate.
            if !forceMode {
                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: settings.closeToTray) { settings.closeToTray.toggle() }
                    Text("Hide to menu bar when window closes (background tasks keep running)")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { settings.closeToTray.toggle() }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                SecondaryButton(title: "Cancel", action: onCancel)
                Button {
                    if hidesOnConfirm { onHideToTray() } else { onConfirm() }
                } label: {
                    Text(confirmTitle)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(hidesOnConfirm ? Pal.mauve : Pal.red, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 24, y: 8)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            Image(lucideSymbol: hasTasks ? "exclamationmark.triangle.fill" : "power")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hasTasks ? Pal.yellow : Pal.mauve)
                .frame(width: 30, height: 30)
                .background((hasTasks ? Pal.yellow : Pal.mauve).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(hasTasks ? "\(model.activeBackgroundCount) background tasks are still running" : "Quit ServerDock?")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                Text(hasTasks ? "Quitting will interrupt the following tasks" : "The app will quit after you confirm")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
            Spacer()
        }
    }
}

// MARK: - Rows

/// Forwarding row observes the host's ForwardManager for live state, with stop/full-manager actions.
private struct HubForwardRow: View {
    let rule: ForwardRule
    @ObservedObject var manager: ForwardManager
    var readOnly: Bool = false
    let onToggle: () -> Void
    let onManage: () -> Void

    private var status: ForwardManager.RuleStatus { manager.status(rule.id) }

    var body: some View {
        rowShell(
            icon: "arrow.left.arrow.right", iconColor: Pal.mauve,
            title: rule.name.isEmpty ? rule.kind.title + String(localized: "Forwarding") : rule.name,
            subtitle: rule.summary,
            statusDot: statusColor, statusText: statusText
        ) {
            if !readOnly {
                iconButton("stop.fill", color: Pal.red, help: String(localized: "Stop"), action: onToggle)
                iconButton("slider.horizontal.3", color: Pal.subtext, help: String(localized: "Manage"), action: onManage)
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .active:   return Pal.green
        case .starting: return Pal.yellow
        case .failed:   return Pal.red
        case .stopped:  return Pal.overlay
        }
    }
    private var statusText: String {
        switch status {
        case .active:   return String(localized: "Running")
        case .starting: return String(localized: "Connecting")
        case .failed(let r): return r
        case .stopped:  return String(localized: "Stopped")
        }
    }
}

/// Transfer row observes live UploadTask progress for upload/download.
private struct HubTransferRow: View {
    @ObservedObject var task: UploadTask
    var readOnly: Bool = false
    let onOpen: () -> Void
    let onClear: () -> Void

    private var fraction: Double {
        task.totalBytes > 0 ? min(1, Double(task.overallSent) / Double(task.totalBytes)) : 0
    }
    private var verb: String { task.direction == .upload ? String(localized: "Upload") : String(localized: "Download") }

    var body: some View {
        rowShell(
            icon: task.direction == .upload ? "arrow.up.circle" : "arrow.down.circle",
            iconColor: transferBlue,
            title: String(localized: "\(verb) \(task.items.count) items"),
            subtitle: subtitle,
            statusDot: statusColor, statusText: statusText,
            progress: (task.phase == .running || task.phase == .paused) ? fraction : nil,
            subtitleTooltip: task.destDir   // Hover reveals the full save path, which is middle-truncated in the subtitle.
        ) {
            if !readOnly {
                switch task.phase {
                case .running:
                    iconButton("pause.fill", color: Pal.mauve, help: String(localized: "Pause")) { AppModel.shared.pauseTransfer(task) }
                    iconButton("xmark", color: Pal.red, help: String(localized: "Cancel")) { task.cancel() }
                case .paused:
                    let waiting = task.awaitingSlot
                    iconButton(waiting ? "clock" : "play.fill",
                               color: waiting ? Pal.subtext : Pal.green,
                               help: waiting ? String(localized: "Waiting for a slot…") : String(localized: "Continue")) { AppModel.shared.resumeTransfer(task) }
                    iconButton("xmark", color: Pal.red, help: String(localized: "Cancel")) { task.cancel() }
                case .queued:
                    iconButton("xmark", color: Pal.red, help: String(localized: "Cancel")) { task.cancel() }
                case .done, .cancelled:
                    iconButton("trash", color: Pal.red, help: String(localized: "Clear History"), action: onClear)
                }
                iconButton("arrow.up.left.and.arrow.down.right", color: Pal.subtext, help: String(localized: "Expand"), action: onOpen)
            }
        }
    }

    private var subtitle: String {
        if task.phase == .running {
            return "\(Int(fraction * 100))%" + (task.speed > 0 ? " · \(Self.rate(task.speed))" : "")
        }
        if task.phase == .paused { return "\(Int(fraction * 100))%" }
        return task.destDir
    }
    private var statusColor: Color {
        if task.pendingAsk != nil { return Pal.yellow }
        switch task.phase {
        case .queued:    return Pal.overlay
        case .running:   return transferBlue
        case .paused:    return task.awaitingSlot ? Pal.overlay : Pal.yellow
        case .done:      return task.hasFailures ? Pal.yellow : Pal.green
        case .cancelled: return Pal.overlay
        }
    }
    private var statusText: String {
        if task.pendingAsk != nil { return String(localized: "Awaiting Confirmation") }
        switch task.phase {
        case .queued:    return String(localized: "Queued")
        case .running:   return task.direction == .upload ? String(localized: "Uploading") : String(localized: "Downloading")
        case .paused:    return task.awaitingSlot ? String(localized: "Waiting for a Slot") : String(localized: "Paused")
        case .done:      return task.hasFailures ? String(localized: "Partially Failed") : String(localized: "Done")
        case .cancelled: return String(localized: "Canceled")
        }
    }

    private static func rate(_ bytesPerSec: Double) -> String {
        let u = ["B", "KB", "MB", "GB"]; var v = bytesPerSec; var i = 0
        while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
        let num = String(format: v >= 100 ? "%.0f" : "%.1f", v)
        return "\(num) \(u[i])/s"
    }
}

/// Extraction row observes ExtractTask without byte-level progress.
private struct HubExtractRow: View {
    @ObservedObject var task: ExtractTask
    var readOnly: Bool = false
    let onOpen: () -> Void
    let onClear: () -> Void

    // Clear only completed/failed records, never pending/ongoing extraction.
    private var isTerminal: Bool {
        switch task.phase { case .done, .failed: return true; default: return false }
    }

    var body: some View {
        rowShell(
            icon: "doc.zipper", iconColor: Pal.mauve,
            title: String(localized: "Extract \(task.archive.name)"),
            subtitle: task.destDir,
            statusDot: statusColor, statusText: statusText,
            progress: nil,
            subtitleTooltip: task.destDir   // Hover reveals the full extraction destination.
        ) {
            if !readOnly {
                if isTerminal {
                    iconButton("trash", color: Pal.red, help: String(localized: "Clear History"), action: onClear)
                }
                iconButton("arrow.up.left.and.arrow.down.right", color: Pal.subtext, help: String(localized: "Expand"), action: onOpen)
            }
        }
    }

    private var statusColor: Color {
        switch task.phase {
        case .ready:   return Pal.overlay
        case .running: return Pal.mauve
        case .done:    return Pal.green
        case .failed:  return Pal.red
        }
    }
    private var statusText: String {
        switch task.phase {
        case .ready:   return String(localized: "Pending Extraction")
        case .running: return String(localized: "Extracting")
        case .done:    return String(localized: "Done")
        case .failed:  return String(localized: "Failed")
        }
    }
}

// MARK: - Shared task row shell

/// Shared row layout: icon, title/subtitle/optional progress, status, and right-side actions.
@ViewBuilder
private func rowShell<Actions: View>(
    icon: String, iconColor: Color,
    title: String, subtitle: String,
    statusDot: Color, statusText: String,
    progress: Double? = nil,
    subtitleTooltip: String? = nil,
    @ViewBuilder actions: () -> Actions
) -> some View {
    HStack(spacing: 10) {
        Image(lucideSymbol: icon).font(.system(size: 13)).foregroundStyle(iconColor)
            .frame(width: 26, height: 26)
            .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                .lineLimit(1).truncationMode(.middle)
            if let p = progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Pal.fill(0.10)).frame(height: 3)
                        Capsule().fill(statusDot).frame(width: max(2, geo.size.width * p), height: 3)
                    }
                }
                .frame(height: 3)
            }
            HStack(spacing: 5) {
                Circle().fill(statusDot).frame(width: 6, height: 6)
                // Truncate long status text first; subtitles take priority so short rates/progress remain complete,
                // while long paths use middle truncation with full hover text.
                Text(statusText).font(.system(size: 10.5)).foregroundStyle(Pal.subtext)
                    .lineLimit(1).truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.overlay)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        .tooltip(subtitleTooltip ?? "", when: subtitleTooltip?.isEmpty == false)
                }
            }
        }
        Spacer(minLength: 6)
        actions()
    }
    .padding(.horizontal, 10).padding(.vertical, 9)
    .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.fill(0.06), lineWidth: 1))
}

/// Compact inline icon button.
private func iconButton(_ symbol: String, color: Color, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(lucideSymbol: symbol).font(.system(size: 10)).foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerCursor()
    .help(help)
}
