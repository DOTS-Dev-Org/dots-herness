// Copyright (c) 2026 DOTS
// Compact language picker with an optional unboxed style for the first-launch gate.

import SwiftUI
import DotsHarnessCore

public struct LanguagePickerButton: View {
    @ObservedObject var model: AppModel
    private let isUnboxed: Bool
    @State private var isPresented = false

    public init(model: AppModel, isUnboxed: Bool = false) {
        self.model = model
        self.isUnboxed = isUnboxed
    }

    public var body: some View {
        pickerButton
            .help(AppCopy.text("settings.language"))
            .accessibilityLabel(AppCopy.text("settings.language"))
            .accessibilityValue(languageName(for: model.appLanguage))
            .popover(isPresented: $isPresented) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(AppLanguage.allCases) { item in
                            Button {
                                model.setAppLanguage(item)
                                isPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    Text(verbatim: item.flagEmoji)
                                    Text(item == .system ? AppCopy.text("language.system") : item.shortCode)
                                    if item == model.appLanguage {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .frame(height: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                        }
                    }
                }
                .frame(width: 200, height: 300)
            }
    }

    @ViewBuilder
    private var pickerButton: some View {
        let button = Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: selectedLanguage.flagEmoji)
                Text(languageName(for: model.appLanguage))
            }
        }

        if isUnboxed {
            button
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func languageName(for language: AppLanguage) -> String {
        language == .system ? AppCopy.effectiveLanguage.nativeName : language.nativeName
    }

    private var selectedLanguage: AppLanguage {
        model.appLanguage == .system ? AppCopy.effectiveLanguage : model.appLanguage
    }
}
