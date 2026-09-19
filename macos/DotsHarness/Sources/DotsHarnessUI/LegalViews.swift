// Copyright (c) 2026 DOTS
// First-run legal gate and the Settings › Legal & Privacy surface.

import SwiftUI
import DotsHarnessCore

private enum LegalDoc: String, CaseIterable, Identifiable {
    case terms, privacy
    var id: String { rawValue }
    var title: String {
        self == .terms ? AppCopy.text("legal.termsTab") : AppCopy.text("legal.privacyTab")
    }
}

private func legalLang() -> String { AppCopy.effectiveLanguage.rawValue }

/// Scrollable viewer for one of the two documents, with a "read on the web" link.
private struct LegalDocumentPanel: View {
    let documents: LegalDocuments
    @State private var selection: LegalDoc

    init(documents: LegalDocuments, initialSelection: LegalDoc = .terms) {
        self.documents = documents
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $selection) {
                ForEach(LegalDoc.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                Text(body(for: selection))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

            Link(AppCopy.text("legal.openWeb"),
                 destination: LegalService.webURL(lang: legalLang(), terms: selection == .terms))
                .font(.footnote)
        }
    }

    private func body(for doc: LegalDoc) -> String {
        doc == .terms ? documents.termsMarkdown : documents.privacyMarkdown
    }
}

private struct ConsentStatements: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.text("legal.consentHeading")).font(.headline)
            ForEach(LegalConsentKey.allCases, id: \.self) { key in
                Text(AppCopy.text("legal.consent.\(key.rawValue)"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LegalAgreementContent: View {
    let documents: LegalDocuments
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppCopy.text("legal.termsTab")).font(.headline)
            Text(documents.termsMarkdown)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            ConsentStatements()

            Divider().padding(.vertical, 4)

            Text(AppCopy.text("legal.privacyTab")).font(.headline)
            Text(documents.privacyMarkdown)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

public struct LegalGateView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Spacer()
                LanguagePickerButton(model: model)

                Button {
                    model.setAppearance(colorScheme == .dark ? .light : .dark)
                } label: {
                    Image(systemName: colorScheme == .dark ? "sun.max.fill" : "moon.fill")
                        .imageScale(.medium)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help(AppCopy.text(colorScheme == .dark ? "appearance.light" : "appearance.dark"))
                .accessibilityLabel(AppCopy.text("settings.theme"))
                .accessibilityValue(AppCopy.text(colorScheme == .dark ? "appearance.light" : "appearance.dark"))
            }
            Text(AppCopy.text("legal.gateHeading")).font(.title2).bold()
            Text(AppCopy.text("legal.gateIntro")).foregroundStyle(.secondary)

            if let documents = model.legalDocuments {
                ScrollView {
                    LegalAgreementContent(documents: documents, model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(AppCopy.text("legal.acceptHint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                HStack {
                    Spacer()
                    Button(AppCopy.text("legal.accept")) { model.acceptLegal() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppCopy.text("legal.loadError")).foregroundStyle(.secondary)
                    Button(AppCopy.text("legal.retry")) {
                        Task { await model.loadLegal() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 620)
        .onChange(of: model.appLanguage) { _, _ in
            Task { await model.loadLegal() }
        }
    }
}

public struct LegalSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var documentToShow: LegalDoc?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(AppCopy.text("legal.title")).font(.title2).bold()
                if model.legalDocuments != nil {
                    HStack(spacing: 12) {
                        Button(AppCopy.text("legal.termsTab")) { documentToShow = .terms }
                        Button(AppCopy.text("legal.privacyTab")) { documentToShow = .privacy }
                    }
                    Text(AppCopy.text("legal.consentPrefs")).font(.title3)
                    ConsentStatements()
                } else {
                    Button(AppCopy.text("legal.retry")) {
                        Task { await model.loadLegal() }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $documentToShow) { document in
            if let documents = model.legalDocuments {
                LegalDocumentPanel(documents: documents, initialSelection: document)
                    .padding()
                    .frame(minWidth: 560, minHeight: 520)
            }
        }
    }
}
