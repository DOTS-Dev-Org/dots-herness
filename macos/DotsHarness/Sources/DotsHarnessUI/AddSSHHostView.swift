// Copyright (c) 2026 DOTS
// One-time setup for a remote work location: confirm the host's fingerprint,
// then hand its password to ssh once so the app can install its own key.

import AppKit
import SwiftUI
import DotsHarnessCore

struct AddSSHHostView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case form
        case scanning
        case fingerprint
        case enrolling
        case failed(String)
        case keyRejected
        case done
    }

    @State private var step: Step = .form
    @State private var alias = ""
    @State private var user = NSUserName()
    @State private var hostName = ""
    @State private var port = "22"
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var scan: SSHEnrollment.HostKeyScan?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppCopy.text("settings.sshAddHost"))
                .font(.headline)

            switch step {
            case .form:
                form
            case .scanning:
                progress(AppCopy.text("ssh.scanning"))
            case .fingerprint:
                fingerprintConfirmation
            case .enrolling:
                progress(AppCopy.text("ssh.enrolling"))
            case .failed(let message):
                failure(message)
            case .keyRejected:
                keyRejected
            case .done:
                VStack(alignment: .leading, spacing: 8) {
                    Label(AppCopy.format("ssh.enrolled", alias), systemImage: "checkmark.circle")
                    Text(AppCopy.text("ssh.enrolled.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(width: 480)
    }

    // MARK: - Steps

    private var form: some View {
        Form {
            TextField(AppCopy.text("settings.sshAlias"), text: $alias)
            TextField(AppCopy.text("settings.sshUser"), text: $user)
            TextField(AppCopy.text("settings.sshHostName"), text: $hostName)
            TextField(AppCopy.text("settings.sshPort"), text: $port)
            SecureField(AppCopy.text("settings.sshPassword"), text: $password)
            Toggle(AppCopy.text("settings.sshRememberPassword"), isOn: $rememberPassword)
            Text(AppCopy.text("settings.sshRememberPassword.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var fingerprintConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.format("ssh.fingerprintTitle", hostName))
                .font(.callout.weight(.medium))
            Text(AppCopy.text("ssh.fingerprintMessage"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(scan?.fingerprints ?? [], id: \.self) { fingerprint in
                Text(fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var keyRejected: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.text("ssh.error.passwordAuthDisabled"))
                .font(.callout)
            Text(AppCopy.text("ssh.installKeyManually"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let key = SSHEnrollment.publicKey() {
                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Button(AppCopy.text("ssh.copyPublicKey")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
            }
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label).font(.callout)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .textSelection(.enabled)
            Text(AppCopy.text("ssh.retryHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private var footer: some View {
        HStack {
            Spacer()
            Button(step == .done ? AppCopy.text("common.done") : AppCopy.text("common.cancel")) {
                dismiss()
            }
            switch step {
            case .form:
                Button(AppCopy.text("ssh.continue")) { Task { await scanHost() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isFormValid)
            case .fingerprint:
                Button(AppCopy.text("ssh.trustAndConnect")) { Task { await enroll() } }
                    .keyboardShortcut(.defaultAction)
            case .failed, .keyRejected:
                Button(AppCopy.text("ssh.retry")) { Task { await enroll() } }
                    .disabled(scan == nil)
            case .scanning, .enrolling, .done:
                EmptyView()
            }
        }
    }

    private var isFormValid: Bool {
        SSHConfigStore.isValidAlias(alias.trimmingCharacters(in: .whitespaces))
            && !hostName.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port).map { (1...65535).contains($0) } == true
    }

    private func scanHost() async {
        step = .scanning
        let result = await model.scanSSHHostKey(
            hostName: hostName.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 22
        )
        switch result {
        case .success(let value):
            scan = value
            step = .fingerprint
        case .failure(let error):
            step = .failed(error.localizedDescription)
        }
    }

    private func enroll() async {
        guard let scan else { return }
        step = .enrolling
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        let trimmedHost = hostName.trimmingCharacters(in: .whitespaces)
        let result: Result<SSHHost, Error>
        if password.isEmpty {
            // Nothing to install with: the host is expected to already accept
            // an existing key or an agent identity.
            result = await model.addSSHHostWithoutPassword(
                alias: trimmedAlias,
                user: trimmedUser,
                hostName: trimmedHost,
                port: Int(port) ?? 22,
                scan: scan
            )
        } else {
            result = await model.enrollSSHHost(
                alias: trimmedAlias,
                user: trimmedUser,
                hostName: trimmedHost,
                port: Int(port) ?? 22,
                password: password,
                scan: scan,
                rememberPassword: rememberPassword
            )
        }
        switch result {
        case .success:
            password = ""
            step = .done
        case .failure(let error):
            password = ""
            if case SSHError.passwordAuthDisabled = error {
                step = .keyRejected
            } else {
                step = .failed(error.localizedDescription)
            }
        }
    }
}
