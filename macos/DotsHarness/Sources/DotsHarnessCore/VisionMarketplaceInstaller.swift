// Copyright (c) 2026 DOTS
// Marketplace bridge for the removable in-process Vision plugin.

import Foundation
import HarnessPluginKit
import PluginRuntime

@MainActor
public final class VisionMarketplaceInstaller: VisionFallbackInstaller {
    private weak var model: AppModel?

    public init(model: AppModel) {
        self.model = model
    }

    public func install() async throws -> (any VisionFallbackService)? {
        guard let model else { throw PluginError.package("App model is unavailable.") }
        if model.marketplace.entries.isEmpty {
            await model.marketplace.refresh()
        }
        guard let entry = model.marketplace.entries.first(where: { $0.id == VisionFallbackDefaults.pluginID }) else {
            throw PluginError.package("Vision plugin is not published in the marketplace.")
        }
        let artifact = entry.currentArtifact
        if !entry.artifacts.isEmpty {
            guard let artifact else {
                throw PluginError.package("Vision plugin has no artifact for this platform.")
            }
            guard artifact.signature != nil else {
                throw PluginError.package("Vision plugin artifact is not signed.")
            }
        } else if entry.signature == nil {
            throw PluginError.package("Vision plugin is not signed.")
        }
        let wasInstalled = model.visionPluginInstalled
        if wasInstalled { model.host.unmountAll() }
        do {
            try await model.marketplace.install(entry)
        } catch {
            if wasInstalled { model.remount() }
            throw error
        }
        model.catalog.setEnabled(VisionFallbackDefaults.pluginID, true)
        model.remount()
        return model.host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self)
    }
}
