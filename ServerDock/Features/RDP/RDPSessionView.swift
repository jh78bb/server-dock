import SwiftUI

/// RDP tab displaying live FreeRDP frames. ContentView's RDPConnectingDialog handles connection/certificates before the tab opens.
struct RDPSessionView: View {
    @ObservedObject var session: RDPSession

    var body: some View {
        VStack(spacing: 0) {
            RemoteDesktopToolbar(session: session)
            Rectangle().fill(Pal.fill(0.08)).frame(height: 1)
            GeometryReader { geo in
                canvas(geo)
                    // Usually connected before the tab appears; correct resolution to its actual size, replacing the estimated connection canvas.
                    // If not connected through this fallback path, connect using the current dimensions.
                    .onAppear {
                        connectIfReady(geo.size)
                        session.requestResize(canvas: geo.size)
                    }
                    .onChange(of: geo.size) { _, new in
                        connectIfReady(new)                 // Fallback: connect at the current size if disconnected.
                        session.requestResize(canvas: new)  // Coalesce remote resizing after dragging stops.
                    }
            }
        }
        // Do not disconnect in onDisappear: switching tabs removes this view, but the model retains the session for background use, like terminal PTYs.
        // Disconnect when a tab closes (AppModel cleans rdpSessions) or its separate window closes (windowWillClose).
    }

    private func mouseLayer(_ img: CGImage) -> RDPMouseLayer {
        RDPMouseLayer(remoteW: img.width, remoteH: img.height,
                      onMove: { session.sendMouseMove($0, $1) },
                      onButton: { session.sendMouseButton($0, down: $1, x: $2, y: $3) },
                      onWheel: { session.sendMouseWheel($0, x: $1, y: $2) },
                      onKey: { session.sendKey($0, down: $1) },
                      onKeyEvent: session.config.protocolType == .vnc
                        ? { session.sendVNCKey($0, down: $1) }
                        : nil,
                      onFlags: { session.sendModifiers($0) })
    }

    @ViewBuilder
    private func canvas(_ geo: GeometryProxy) -> some View {
        ZStack {
            Color.black
            if let img = session.image {
                if let z = session.zoom {
                    // Render zoomed remote pixels divided by backing scale, multiplied by zoom; scroll oversized content, with Option-scroll panning.
                    let scale = NSScreen.main?.backingScaleFactor ?? 2
                    let w = CGFloat(img.width) / scale * z, h = CGFloat(img.height) / scale * z
                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            Image(decorative: img, scale: 1).resizable().interpolation(z >= 1 ? .none : .low).frame(width: w, height: h)
                            mouseLayer(img).frame(width: w, height: h)
                        }
                        .frame(width: w, height: h)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                } else {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.low)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    mouseLayer(img)
                }
                if session.viewOnly {
                    VStack { HStack { Spacer()
                        Label(String(localized: "View only"), lucideSymbol: "eye").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4).background(.black.opacity(0.55), in: Capsule()).padding(10)
                    }; Spacer() }.allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectIfReady(_ size: CGSize) {
        guard size.width > 200, size.height > 200 else { return }
        session.connect(canvas: size)
    }
}

/// ContentView-level RDP connection dialog with a translucent full-window overlay and centered card over the current overview/list.
/// Driven by a connecting session without a tab; after a successful first frame, open a tab with that existing session for a seamless desktop transition.
/// Show the certificate prompt instead when trust is pending, avoiding stacked overlays.
struct RDPConnectingDialog: View {
    @ObservedObject var session: RDPSession
    let onConnected: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            if let prompt = session.certPrompt {
                RDPCertDialog(prompt: prompt).transition(.opacity)
            } else if let prompt = session.vncCredentialPrompt {
                VNCPasswordDialog(
                    host: session.config.host,
                    port: session.config.port,
                    requiresUsername: prompt.requiresUsername,
                    message: prompt.message,
                    initialUsername: prompt.prefillUsername,
                    onSubmit: { session.submitVNCCredentials(username: $0, password: $1, save: $2) },
                    onCancel: { session.cancelVNCCredentialPrompt() }
                ).transition(.opacity)
            } else {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    RDPConnectingPanel(session: session, onCancel: onCancel, onRetry: { session.retry() })
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.certPrompt?.id)
        .animation(.easeOut(duration: 0.15), value: session.vncCredentialPrompt?.id)
        // Open the tab/window only after the first complete frame settles, avoiding partially painted desktop flashes.
        .onChange(of: session.ready) { isReady in
            if isReady { onConnected() }
        }
    }
}

private struct VNCPasswordDialog: View {
    let host: String
    let port: Int
    let requiresUsername: Bool
    let message: String?
    var initialUsername: String = ""
    let onSubmit: (String, String, Bool) -> Void
    let onCancel: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var save = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("VNC Password Required")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                Text("Enter credentials for \(host):\(port).")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(Pal.red)
                }
                if requiresUsername {
                    ThemedTextField(placeholder: "Username", text: $username)
                }
                ThemedSecureField(placeholder: "Password", text: $password)
                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: save) { save.toggle() }
                    Text("Save these credentials after a successful login")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { save.toggle() }
                }
                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "Cancel", action: onCancel)
                    PrimaryButton(title: "Connect", enabled: !password.isEmpty && (!requiresUsername || !username.trimmingCharacters(in: .whitespaces).isEmpty)) {
                        onSubmit(username.trimmingCharacters(in: .whitespaces), password, save)
                    }
                }
            }
            .padding(22)
            .frame(width: 400)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 22, y: 8)
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { if username.isEmpty { username = initialUsername } }
    }
}

/// After connection, choose an inline tab or new window, optionally remembering the choice in settings.
struct RDPOpenDialog: View {
    let hostName: String
    let onChoose: (_ window: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void
    @State private var remember = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text("Open Remote Desktop").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("How should \"\(hostName)\" be opened?")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: remember) { remember.toggle() }
                    Text("Remember my choice (can be changed in Settings)")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { remember.toggle() }
                }
                HStack(spacing: 10) {
                    SecondaryButton(title: "Cancel", action: onCancel)
                    Spacer()
                    SecondaryButton(title: "New Window") { onChoose(true, remember) }
                    PrimaryButton(title: "Inline Tabs") { onChoose(false, remember) }
                }
            }
            .padding(20)
            .frame(width: 400)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}

/// Centered connection-progress card: target row, three steps, and live logs.
/// Hide after a successful frame. Cancel is always available; failures/disconnections also offer Retry.
private struct RDPConnectingPanel: View {
    @ObservedObject var session: RDPSession
    let onCancel: () -> Void
    let onRetry: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    private var cfg: RDPConnection { session.config }
    private var target: String {
        cfg.protocolType == .vnc ? "\(cfg.host):\(cfg.port)" : "\(cfg.user)@\(cfg.host):\(cfg.port)"
    }

    private var ended: Bool {   // Offer Retry after failure/disconnection; Cancel remains available.
        switch session.phase { case .failed, .disconnected: return true; default: return false }
    }

    private var statusColor: Color {
        switch session.phase {
        case .pending, .connecting: return Pal.yellow
        case .connected: return Pal.green
        case .failed, .disconnected: return Pal.red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connecting").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            // Target row and overall status.
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(target).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                Spacer()
                Text(session.connectStatusText).font(.system(size: 12, weight: .medium)).foregroundStyle(statusColor)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            // Steps.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.connectSteps) { stepRow($0) }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            // Live logs.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Live Log").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.overlay)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            logText
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("logBottom")
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: session.logs.count) { _ in proxy.scrollTo("logBottom", anchor: .bottom) }
                }
            }
            .frame(height: 150)
            .background(theme.isDark ? Pal.fill(0.03) : Pal.fill(0.02))

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            HStack(spacing: 10) {
                Spacer()
                SecondaryButton(title: "Cancel") { onCancel() }   // Cancel is always available.
                if ended {
                    PrimaryButton(title: "Retry") { onRetry() }   // Also offer Retry after failure/disconnection.
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 480)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    /// Combine logs into one Text with timestamps/severity colors, allowing multiline selection/copy.
    private var logText: Text {
        session.logs.reduce(Text(verbatim: "")) { acc, line in
            let stamp = line.time.isEmpty ? "" : line.time + "  "
            let color: Color = line.level >= 2 ? Pal.red : (line.level == 1 ? Pal.yellow : Pal.subtext)
            return acc
                + Text(verbatim: stamp).foregroundColor(Pal.overlay)
                + Text(verbatim: line.message + "\n").foregroundColor(color)
        }
    }

    private func stepRow(_ step: RDPConnectStep) -> some View {
        HStack(spacing: 10) {
            stepIcon(step.state).frame(width: 18)
            Text(step.title).font(.system(size: 13))
                .foregroundStyle(step.state == .pending ? Pal.overlay : Pal.text)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stepIcon(_ state: RDPConnectStep.State) -> some View {
        switch state {
        case .pending: Image(lucideSymbol: "circle").font(.system(size: 13)).foregroundStyle(Pal.overlay)
        case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
        case .success: Image(lucideSymbol: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.green)
        case .failure: Image(lucideSymbol: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.red)
        }
    }
}

/// Viewer toolbar: view-only, key combinations, screenshot, zoom/actual size, window fit/fullscreen, disconnect/reconnect.
struct RemoteDesktopToolbar: View {
    @ObservedObject var session: RDPSession
    @ObservedObject private var theme = ThemeManager.shared
    private var accent: Color { session.host.accent }
    private var live: Bool { session.isLive }

    var body: some View {
        HStack(spacing: 6) {
            group {
                toggle("cursorarrow.click", String(localized: "Control"), on: !session.viewOnly) { session.viewOnly = false }
                toggle("eye", String(localized: "View only — don't send mouse or keyboard"), on: session.viewOnly) { session.viewOnly = true }
            }
            group {
                Menu {
                    ForEach(RDPSession.Shortcut.allCases) { s in Button(s.title) { session.send(s) } }
                } label: { icon("command") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!live).help(String(localized: "Send Key Combination"))
                Menu {
                    Button(String(localized: "Copy Screenshot")) { copyScreenshot() }
                    Button(String(localized: "Save Screenshot…")) { saveScreenshot() }
                } label: { icon("camera") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(session.image == nil).help(String(localized: "Screenshot"))
            }
            group {
                button("minus.magnifyingglass", String(localized: "Zoom Out"), enabled: session.image != nil) { zoom(by: 0.8) }
                button("1.magnifyingglass", String(localized: "Actual Size (100%)"), enabled: session.image != nil, on: session.zoom == 1) { session.zoom = 1 }
                button("plus.magnifyingglass", String(localized: "Zoom In"), enabled: session.image != nil) { zoom(by: 1.25) }
                button("arrow.up.left.and.down.right.magnifyingglass", String(localized: "Fit to Window"), enabled: session.image != nil, on: session.zoom == nil) { session.zoom = nil }
            }
            group {
                button("rectangle.expand.vertical", String(localized: "Resize Window to Remote Screen"), enabled: session.image != nil) { resizeWindowToRemote() }
                button("arrow.up.left.and.arrow.down.right", String(localized: "Full Screen"), enabled: true) { NSApp.keyWindow?.toggleFullScreen(nil) }
            }
            Spacer(minLength: 8)
            if let z = session.zoom { Text("\(Int((z * 100).rounded()))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay) }
            if live {
                button("power", String(localized: "Disconnect"), enabled: true, tint: Pal.red) { session.disconnect() }
            } else if session.phase != .connecting {
                Button { session.retry() } label: {
                    Label(String(localized: "Reconnect"), lucideSymbol: "arrow.clockwise").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(accent, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Pal.base)
    }

    // MARK: Components

    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 2) { c() }.padding(2).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ symbol: String, on: Bool = false, tint: Color? = nil) -> some View {
        Image(lucideSymbol: symbol).font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint ?? (on ? accent : Pal.subtext))
            .frame(width: 28, height: 24)
            .background(on ? accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }

    private func toggle(_ symbol: String, _ help: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol, on: on) }.buttonStyle(.plain).pointerCursor().help(help)
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool, on: Bool = false, tint: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol, on: on, tint: tint) }
            .buttonStyle(.plain).pointerCursor(enabled).disabled(!enabled).opacity(enabled ? 1 : 0.4).help(help)
    }

    // MARK: Actions

    private func zoom(by f: Double) {
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let current = session.zoom ?? 1
        _ = scale
        session.zoom = min(4, max(0.25, (current * f * 100).rounded() / 100))
    }

    private func copyScreenshot() {
        guard let data = session.screenshotPNG(), let img = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img])
    }

    private func saveScreenshot() {
        guard let data = session.screenshotPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "\(session.host.name) \(f.string(from: Date())).png"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    /// Fit window content to remote point dimensions, capped at the screen bounds.
    private func resizeWindowToRemote() {
        guard let img = session.image, let win = NSApp.keyWindow, let content = win.contentView else { return }
        let scale = win.screen?.backingScaleFactor ?? 2
        let wantW = CGFloat(img.width) / scale, wantH = CGFloat(img.height) / scale + 35   // Allowance for the toolbar and separator.
        var frame = win.frame
        let dw = wantW - content.bounds.width, dh = wantH - content.bounds.height
        frame.size.width += dw; frame.size.height += dh; frame.origin.y -= dh
        if let vis = win.screen?.visibleFrame { frame.size.width = min(frame.width, vis.width); frame.size.height = min(frame.height, vis.height); frame.origin.y = max(vis.minY, frame.origin.y) }
        win.setFrame(frame, display: true, animate: true)
        session.zoom = nil
    }
}
