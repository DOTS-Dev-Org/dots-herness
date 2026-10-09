// Copyright (c) 2026 DOTS
// Members, invites, preferences and decisions.

import CryptoKit
import Foundation
import PluginRuntime

extension WorkspaceMemory {
    public func accessStatus() -> WorkspaceAccessStatus {
        let member = currentMember()
        return WorkspaceAccessStatus(
            personID: identity?.personID ?? "",
            deviceID: identity?.deviceID ?? "",
            role: (member?["role"] as? String).flatMap(MemoryRole.init(rawValue:)),
            score: member?["score"] as? Int ?? 0,
            memberCount: (state["members"] as? [[String: Any]] ?? []).count,
            pendingDecisionCount: (state["pendingProposals"] as? [[String: Any]] ?? []).count,
            revision: revision,
            memoryReady: manifest != nil
        )
    }

    public func memberSummaries() -> [[String: String]] {
        (state["members"] as? [[String: Any]] ?? []).compactMap { member in
            guard let personID = member["personId"] as? String,
                  let deviceID = member["deviceId"] as? String else { return nil }
            return [
                "personId": personID,
                "deviceId": deviceID,
                "displayName": member["displayName"] as? String ?? "",
                "role": member["role"] as? String ?? MemoryRole.observer.rawValue,
                "score": String(member["score"] as? Int ?? 0),
                "revoked": String(member["revoked"] as? Bool ?? false),
            ]
        }
    }

    public func pendingDecisions() -> [[String: Any]] {
        state["pendingProposals"] as? [[String: Any]] ?? []
    }

    public func createInvite(
        personID: String = UUID().uuidString,
        displayName: String,
        role: MemoryRole = .contributor,
        score: Int = 50,
        publicKey: String
    ) throws -> String {
        guard canWrite(role: .owner), let identity else { throw WorkspaceMemoryError.unauthorized }
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "projectId": projectID ?? "",
            "personId": personID,
            "displayName": sanitize(displayName, limit: 80),
            "role": role.rawValue,
            "score": max(0, min(100, score)),
            "publicKey": publicKey,
            "invitedBy": identity.personID,
            "createdAt": isoNow(),
        ]
        let eventID = try writeEvent(type: "member.invited", scope: "device", payload: payload)
        payload["eventId"] = eventID
        payload["actor"] = [
            "personId": identity.personID,
            "deviceId": identity.deviceID,
            "keyId": identity.keyID,
            "publicKey": identity.publicKey,
        ]
        let signed = try signedObject(payload, key: privateKey, actor: identity)
        guard let data = try? JSONSerialization.data(withJSONObject: signed, options: [.sortedKeys]) else {
            throw WorkspaceMemoryError.invalidInvitation
        }
        return data.base64EncodedString()
    }

    public func acceptInvite(_ token: String) throws {
        try ensureIdentity()
        guard let data = Data(base64Encoded: token),
              let invitation = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projectID = invitation["projectId"] as? String,
              projectID == self.projectID,
              let publicKey = invitation["publicKey"] as? String,
              publicKey == identity?.publicKey else {
            throw WorkspaceMemoryError.invalidInvitation
        }
        guard let signed = invitation["signature"] as? [String: Any],
              let signature = signed["value"] as? String,
              let rootKey = rootPublicKey,
              verify(signature: signature, object: invitationWithoutSignature(invitation), publicKey: rootKey) else {
            throw WorkspaceMemoryError.invalidInvitation
        }
        _ = try writeEvent(
            type: "member.accepted",
            scope: "device",
            payload: [
                "personId": invitation["personId"] as Any,
                "deviceId": identity?.deviceID as Any,
                "displayName": invitation["displayName"] as Any,
                "role": invitation["role"] as Any,
                "score": invitation["score"] as Any,
                "publicKey": publicKey,
            ]
        )
    }

    /// Records a lasting actor preference. The projection supersedes any earlier
    /// value under the same key, so repeated calls never pile up.
    public func setPreference(key: String, value: String) throws {
        guard let identity else { throw WorkspaceMemoryError.noWorkspace }
        _ = try writeEvent(type: "preference.set", scope: "person", payload: [
            "personId": identity.personID,
            "key": sanitize(key, limit: 60),
            "value": sanitize(value, limit: 240),
        ])
        syncFacts()
    }

    /// Records a fact about the user that holds in every project. It needs no
    /// workspace: the profile lives beside the app's settings, not in a repository.
    public func setUserPreference(key: String, value: String) throws {
        try profile.setPreference(key: sanitize(key, limit: 60), value: sanitize(value, limit: 240))
    }

    /// Records a project-wide fact - what this project is for, what it must not
    /// do. Writable by an owner or approver, which is what the person who created
    /// the vault already is; an invited contributor cannot rewrite the brief.
    public func setProjectDefault(key: String, value: String) throws {
        _ = try writeEvent(type: "project.default.set", scope: "project", payload: [
            "key": sanitize(key, limit: 60),
            "value": sanitize(value, limit: ProjectKnowledge.limit(forKey: sanitize(key, limit: 60))),
        ])
        syncFacts()
    }

    /// Takes a project entry out of the prompt. The event stays in the log.
    public func forgetProjectDefault(key: String) throws {
        _ = try writeEvent(type: "project.default.set", scope: "project", payload: ["key": sanitize(key, limit: 60)])
        syncFacts(removing: Fact(kind: "project", key: sanitize(key, limit: 60), text: ""))
    }

    /// The project entries: this host's own, and those another client recorded
    /// in the facts file. Its own win where both name a key.
    public var projectDefaults: [String: String] {
        let own = ((state["projectDefaults"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
        return own.merging(foreignFacts("project", knownKeys: Set(own.keys))) { own, _ in own }
    }

    /// True once the project brief has any entry, so the host asks for one only
    /// while the vault still knows nothing about the project. What was learned
    /// from the code is not a brief: only the user can say what the project is for.
    public var hasProjectBrief: Bool {
        projectDefaults.keys.contains { !ProjectKnowledge.keys.contains($0) }
    }

    /// The knowledge entries nobody has recorded yet.
    public var missingKnowledge: [String] {
        let defaults = projectDefaults
        return ProjectKnowledge.keys.filter { defaults[$0] == nil }
    }

    public func proposeDecision(summary: String, details: [String: Any] = [:]) throws {
        guard canWrite(role: .contributor) else { throw WorkspaceMemoryError.unauthorized }
        var payload = details
        payload["summary"] = sanitize(summary, limit: 240)
        _ = try writeEvent(type: "decision.proposed", scope: "project", payload: payload)
    }

    public func revoke(deviceID: String) throws {
        guard canWrite(role: .owner) else { throw WorkspaceMemoryError.unauthorized }
        _ = try writeEvent(type: "member.revoked", scope: "device", payload: ["deviceId": deviceID])
    }

    public func updateMember(deviceID: String, role: MemoryRole, score: Int, displayName: String? = nil) throws {
        guard canWrite(role: .owner) else { throw WorkspaceMemoryError.unauthorized }
        var payload: [String: Any] = [
            "deviceId": deviceID,
            "role": role.rawValue,
            "score": max(0, min(100, score)),
        ]
        if let displayName { payload["displayName"] = sanitize(displayName, limit: 80) }
        _ = try writeEvent(type: "member.updated", scope: "device", payload: payload)
    }

    public func resolveDecision(eventID: String, accept: Bool) throws {
        guard canWrite(role: .approver) else { throw WorkspaceMemoryError.unauthorized }
        guard let proposal = (state["pendingProposals"] as? [[String: Any]])?.first(where: { $0["eventId"] as? String == eventID }) else {
            return
        }
        if accept {
            _ = try writeEvent(type: "decision.accepted", scope: "project", supersedes: proposal["supersedes"] as? [String] ?? [], payload: proposal)
        } else {
            _ = try writeEvent(type: "decision.rejected", scope: "project", payload: ["proposalEventId": eventID])
        }
    }

    private func currentMember() -> [String: Any]? {
        guard let deviceID = identity?.deviceID else { return nil }
        return member(deviceID: deviceID)
    }

    func member(deviceID: String) -> [String: Any]? {
        (state["members"] as? [[String: Any]] ?? []).first { $0["deviceId"] as? String == deviceID }
    }

    func upsertMember(_ payload: [String: Any]) {
        guard let deviceID = payload["deviceId"] as? String else { return }
        var members = state["members"] as? [[String: Any]] ?? []
        members.removeAll { $0["deviceId"] as? String == deviceID }
        members.append(payload)
        state["members"] = members
    }

    func setMember(deviceID: String, key: String, value: Any) {
        var members = state["members"] as? [[String: Any]] ?? []
        guard let index = members.firstIndex(where: { $0["deviceId"] as? String == deviceID }) else { return }
        members[index][key] = value
        state["members"] = members
    }

    func canWrite(role required: MemoryRole) -> Bool {
        guard let member = currentMember(),
              member["revoked"] as? Bool != true,
              let role = member["role"] as? String,
              let actual = MemoryRole(rawValue: role) else { return false }
        return actual.rank >= required.rank
    }

    func canWrite(for type: String) -> Bool {
        switch type {
        case "workspace.initialized": return true
        case "member.accepted": return true
        case "member.invited", "member.revoked", "member.updated": return canWrite(role: .owner)
        case "decision.accepted", "decision.rejected", "project.default.set": return canWrite(role: .approver)
        case "preference.set": return canWrite(role: .observer)
        default: return canWrite(role: .contributor)
        }
    }
}
