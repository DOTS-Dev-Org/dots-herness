// Copyright (c) 2026 DOTS
// Multiplatform version checking and release discovery endpoints.

import { Hono } from "hono";
import type { Env, AppVariables } from "../../env";

export const DEFAULT_APP_VERSION = "0.1.0";

export interface PlatformReleaseInfo {
  latest_version: string;
  build_number: number;
  min_supported_version: string;
  download_url: string;
  release_notes: string;
  published_at: string;
}

export const PLATFORM_RELEASES: Record<string, PlatformReleaseInfo> = {
  macos: {
    latest_version: DEFAULT_APP_VERSION,
    build_number: 1,
    min_supported_version: "0.1.0",
    download_url: `https://github.com/DOTS-Dev-Org/dots-herness/releases/latest/download/DotsHarness-${DEFAULT_APP_VERSION}.dmg`,
    release_notes: "İlk kararlı macOS sürümü (Swift/SwiftUI).",
    published_at: "2026-09-21T00:00:00Z",
  },
  windows: {
    latest_version: DEFAULT_APP_VERSION,
    build_number: 1,
    min_supported_version: "0.1.0",
    download_url: `https://github.com/DOTS-Dev-Org/dots-herness/releases/latest/download/DotsHarness-${DEFAULT_APP_VERSION}-win-x64.zip`,
    release_notes: "Windows sürümü (.NET 8 WPF); çalıştırmak için .NET 8 Desktop Runtime gerekir.",
    published_at: "2026-09-21T00:00:00Z",
  },
  linux: {
    latest_version: DEFAULT_APP_VERSION,
    build_number: 1,
    min_supported_version: "0.1.0",
    download_url: `https://github.com/DOTS-Dev-Org/dots-herness/releases/latest/download/DotsHarness-${DEFAULT_APP_VERSION}-linux-x64.tar.xz`,
    release_notes: "Linux Avalonia sürümü; çalıştırmak için .NET 8 Runtime gerekir.",
    published_at: "2026-09-21T00:00:00Z",
  },
  ios: {
    latest_version: DEFAULT_APP_VERSION,
    build_number: 1,
    min_supported_version: "0.1.0",
    download_url: "https://apps.apple.com/app/dots-herness/id6470000000",
    release_notes: "İlk kararlı iOS sürümü.",
    published_at: "2026-09-21T00:00:00Z",
  },
  android: {
    latest_version: DEFAULT_APP_VERSION,
    build_number: 1,
    min_supported_version: "0.1.0",
    download_url: "https://play.google.com/store/apps/details?id=com.dots.herness.mobile",
    release_notes: "İlk kararlı Android sürümü.",
    published_at: "2026-09-21T00:00:00Z",
  },
};

/**
 * Compare two SemVer strings (MAJOR.MINOR.PATCH).
 * Returns:
 *   -1 if v1 < v2
 *    0 if v1 == v2
 *    1 if v1 > v2
 */
export function compareSemver(v1: string, v2: string): number {
  const clean1 = v1.replace(/^v/, "").split("-")[0];
  const clean2 = v2.replace(/^v/, "").split("-")[0];

  const p1 = clean1.split(".").map((n) => parseInt(n, 10) || 0);
  const p2 = clean2.split(".").map((n) => parseInt(n, 10) || 0);

  for (let i = 0; i < Math.max(p1.length, p2.length, 3); i++) {
    const num1 = p1[i] || 0;
    const num2 = p2[i] || 0;
    if (num1 < num2) return -1;
    if (num1 > num2) return 1;
  }
  return 0;
}

export const versionRoutes = new Hono<{ Bindings: Env; Variables: AppVariables }>();

// GET /version.json or /harness/version.json
versionRoutes.get("/version.json", (c) => {
  c.header("Cache-Control", "public, max-age=60, s-maxage=60");
  return c.json({
    active: true,
    default_version: DEFAULT_APP_VERSION,
    platforms: PLATFORM_RELEASES,
  });
});

// GET /check-update or /harness/check-update
versionRoutes.get("/check-update", (c) => {
  const platform = (c.req.query("platform") || "macos").toLowerCase();
  const currentVersion = c.req.query("version") || "";
  const currentBuild = parseInt(c.req.query("build") || "0", 10);

  const release = PLATFORM_RELEASES[platform] || PLATFORM_RELEASES.macos;

  if (!currentVersion) {
    return c.json({
      platform,
      latest_version: release.latest_version,
      build_number: release.build_number,
      min_supported_version: release.min_supported_version,
      update_available: false,
      mandatory: false,
      release_notes: release.release_notes,
      download_url: release.download_url,
      published_at: release.published_at,
    });
  }

  const semverComparison = compareSemver(currentVersion, release.latest_version);
  const isOlderVersion = semverComparison < 0;
  const isSameVersionOlderBuild = semverComparison === 0 && currentBuild > 0 && currentBuild < release.build_number;

  const updateAvailable = isOlderVersion || isSameVersionOlderBuild;
  const isMandatory = compareSemver(currentVersion, release.min_supported_version) < 0;

  c.header("Cache-Control", "public, max-age=60, s-maxage=60");
  return c.json({
    platform,
    current_version: currentVersion,
    latest_version: release.latest_version,
    build_number: release.build_number,
    min_supported_version: release.min_supported_version,
    update_available: updateAvailable,
    mandatory: isMandatory,
    release_notes: release.release_notes,
    download_url: release.download_url,
    published_at: release.published_at,
  });
});
