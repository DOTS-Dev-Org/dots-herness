// Copyright (c) 2026 DOTS

import SwiftUI
import WebKit
import DotsHarnessCore

struct DockBrowserTabTitle: View {
    @ObservedObject var service: NativeBrowserService

    var body: some View {
        Text(service.pageTitle.isEmpty
             ? (URL(string: service.currentURLString)?.host ?? AppCopy.text("dock.newTab"))
             : service.pageTitle)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct DockWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct DockBrowserView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: RightDockState
    @ObservedObject var service: NativeBrowserService
    @State private var inputAddress = ""
    @FocusState private var addressFocused: Bool

    private var isNewTab: Bool { service.currentURLString.isEmpty || service.currentURLString == "about:blank" }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            if let error = service.navigationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(10)
            }
            if isNewTab {
                tools
            } else {
                DockWebViewHost(webView: service.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A page in a hidden tab or closed dock keeps playing video and audio;
                    // suspend its media until the tab is on screen again.
                    .onAppear { service.webView.setAllMediaPlaybackSuspended(false) }
                    .onDisappear { service.webView.setAllMediaPlaybackSuspended(true) }
            }
        }
        .onAppear { inputAddress = isNewTab ? "" : service.currentURLString }
        .onChange(of: service.currentURLString) { _, url in
            if !addressFocused { inputAddress = url == "about:blank" ? "" : url }
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused { inputAddress = isNewTab ? "" : service.currentURLString }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                navigationButton("chevron.left", title: "navigation.back", enabled: service.canGoBack) { service.goBack() }
                navigationButton("chevron.right", title: "navigation.forward", enabled: service.canGoForward) { service.goForward() }
                navigationButton(service.isLoading ? "xmark" : "arrow.clockwise",
                                 title: service.isLoading ? "common.stop" : "settings.reload", enabled: !isNewTab) {
                    if service.isLoading { service.stop() } else { service.reload() }
                }
            }
            .background(Color.primary.opacity(0.06), in: Capsule())

            TextField(AppCopy.text("dock.address"), text: $inputAddress)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($addressFocused)
                .accessibilityLabel(AppCopy.text("dock.address"))
                .onSubmit {
                    let address = inputAddress
                    addressFocused = false
                    service.loadAddress(address)
                    inputAddress = service.currentURLString
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 50, maxWidth: .infinity)
                .frame(height: 32)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .overlay(alignment: .bottom) {
                    if service.isLoading { ProgressView().progressViewStyle(.linear).scaleEffect(y: 0.5).padding(.horizontal, 10) }
                }

            Menu {
                Button(AppCopy.text("dock.openExternal")) {
                    if let url = URL(string: service.currentURLString) { SafeURL.openWeb(url) }
                }.disabled(isNewTab)
                Button(AppCopy.text("router.copyURL")) {
                    NSPasteboard.copy(service.currentURLString)
                }.disabled(isNewTab)
                Divider()
                Button(AppCopy.text("dock.bottomTerminal")) { state.openTerminal(model: model, at: .bottom) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 32)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(AppCopy.text("conversation.tools"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func navigationButton(_ icon: String, title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 26, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(AppCopy.text(title))
        .accessibilityLabel(AppCopy.text(title))
    }

    private func toolButton(_ action: KeyboardShortcutAction) -> some View {
        Button { state.perform(action, model: model) } label: {
            HStack(spacing: 6) {
                Image(systemName: action.systemImage).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(action.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                Text(model.shortcut(for: action).displayValue)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.075), in: Capsule())
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaneChoiceButtonStyle())
        .accessibilityLabel(action.title)
    }

    private var tools: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppCopy.text("conversation.tools"))
                    .font(.system(size: 13, weight: .medium))
                    .padding(.bottom, 10)
                ForEach([KeyboardShortcutAction.review, .terminal, .files]) { action in
                    HStack(spacing: 4) {
                        toolButton(action)
                        if action == .terminal {
                            Menu {
                                Button(AppCopy.text("dock.bottomTerminal")) { state.openTerminal(model: model, at: .bottom) }
                            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 32) }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel(AppCopy.text("dock.bottomTerminal"))
                        }
                    }
                }
            }
            .padding(20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
