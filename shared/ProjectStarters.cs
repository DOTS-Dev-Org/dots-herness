// Copyright (c) 2026 DOTS
// The shipped project-starter catalog. It is what the Marketplace shows until
// the first successful fetch, so the Starters tab is never empty. Mirrors
// ProjectStarter.all in the macOS MarketplaceSectionView.

namespace DotsHarnessCore;

public static class ProjectStarters
{
    /// <summary>
    /// A project scaffold: a folder the user picks plus a first message that
    /// builds it. The prompt is sent to the agent as written; the model reads
    /// English regardless of the interface language.
    /// </summary>
    public sealed record Starter(
        string Id,
        string Title,
        string Detail,
        string Category,
        string Prompt);

    public static IReadOnlyList<Starter> All { get; } =
    [
        new("web", "Web app", "Next.js App Router app with a home page and an API route.", "web",
            """
            Scaffold a Next.js (App Router, TypeScript) web app in this empty folder: a home page, a shared layout, \
            one example API route, ESLint, and a README with run commands. Install dependencies and confirm it builds.
            """),
        new("landing", "Landing page", "Static landing page with hero, features, pricing and contact.", "web",
            """
            Scaffold a static landing page in this empty folder with plain HTML, CSS and a little JavaScript, no build step: \
            hero, features, pricing and contact sections, responsive down to phone width. Add a README on how to preview it.
            """),
        new("api", "API service", "FastAPI service with a health endpoint and one CRUD resource.", "backend",
            """
            Scaffold a FastAPI service in this empty folder: a health endpoint, one example CRUD resource with Pydantic models, \
            settings from environment variables, pytest tests, and a README with run commands. Verify the tests pass.
            """),
        new("ios", "iOS app", "SwiftUI iOS app as a Swift package plus an XcodeGen project.", "mobile",
            """
            Scaffold a SwiftUI iOS app in this empty folder as a Swift package plus an XcodeGen project.yml: a tab view with \
            two example screens, an observable model, and one unit test. Add a README on how to generate and run the project.
            """),
        new("worker", "Cloudflare Worker", "Worker with a JSON API, typed bindings and a vitest test.", "backend",
            """
            Scaffold a Cloudflare Worker (TypeScript) in this empty folder with wrangler: a JSON API with two routes, \
            typed environment bindings, a vitest test, and a README covering local dev and deploy.
            """),
        new("cli", "Command-line tool", "Python CLI with argparse, two subcommands and pytest tests.", "tools",
            """
            Scaffold a Python command-line tool in this empty folder with a pyproject.toml: an argparse entry point with two \
            subcommands, a tests folder with pytest, and a README with install and usage. Verify the tests pass.
            """),
    ];

    /// <summary>
    /// The starters to show: the server's catalog when it answered, the
    /// shipped one otherwise.
    /// </summary>
    public static IReadOnlyList<MarketStarter> Effective(IReadOnlyList<MarketStarter> remote)
    {
        if (remote.Count > 0) return remote;
        return All.Select(starter => new MarketStarter(
            starter.Id,
            starter.Prompt,
            starter.Title,
            starter.Detail,
            starter.Category)).ToList();
    }
}
