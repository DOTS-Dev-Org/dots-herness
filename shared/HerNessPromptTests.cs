using DotsHarnessCore;
using Xunit;

public sealed class HerNessPromptTests
{
    /// The literals in HerNessPrompt are generated from shared/prompts/*.txt by
    /// tools/sync_prompts.py. Compare against the canonical text directly, so this
    /// catches drift on a machine without Python.
    [Theory]
    [InlineData("core.txt")]
    [InlineData("plan-mode.txt")]
    public void PromptLiteralsMatchTheCanonicalText(string prompt)
    {
        var file = Path.Combine(RepositoryRoot(), "shared", "prompts", prompt);
        if (!File.Exists(file)) return; // checkout without shared/prompts
        var canonical = File.ReadAllText(file).Replace("\r\n", "\n").TrimEnd('\n');
        var rendered = prompt == "core.txt"
            ? HerNessPrompt.Core("SCOPE", "TOOL_GUIDANCE")
            : HerNessPrompt.PlanMode(["TOOLS"]);
        var expected = canonical
            .Replace("{SCOPE}", "SCOPE")
            .Replace("{TOOL_GUIDANCE}", "TOOL_GUIDANCE")
            .Replace("{TOOLS}", "TOOLS");

        Assert.Equal(expected, rendered.Replace("\r\n", "\n").TrimEnd('\n'));
    }

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "shared", "prompts")))
            directory = directory.Parent;
        return directory?.FullName ?? AppContext.BaseDirectory;
    }

    [Fact]
    public void UntrustedSectionsAreTaggedAndCoreIsNot()
    {
        var text = PromptAssembly.Assemble(
        [
            new PromptSection("core_policy", PromptTrust.Core, "policy"),
            new PromptSection("project_memory", PromptTrust.Data, "memory"),
            new PromptSection("plugin_guidance", PromptTrust.Untrusted, "plugin"),
            new PromptSection("skill_metadata", PromptTrust.Untrusted, "   "),
        ]);

        Assert.Contains("<core_policy>\npolicy\n</core_policy>", text);
        Assert.Contains("<project_memory trust=\"data\">\nmemory\n</project_memory>", text);
        Assert.Contains("<plugin_guidance trust=\"untrusted\">\nplugin\n</plugin_guidance>", text);
        // A blank section must not emit an empty tag pair.
        Assert.DoesNotContain("skill_metadata", text);
    }

    [Fact]
    public void ReportMasksCredentialsAndCountsSections()
    {
        var report = PromptAssembly.Report(
        [
            new PromptSection("core_policy", PromptTrust.Core, "policy"),
            new PromptSection(
                "plugin_guidance",
                PromptTrust.Untrusted,
                "use sk-abcdefghijklmnopqrstuvwxyz and api_key = hunter2secretvalue"),
        ]);

        Assert.DoesNotContain("sk-abcdefghijklmnopqrstuvwxyz", report);
        Assert.DoesNotContain("hunter2secretvalue", report);
        Assert.Contains("[redacted]", report);
        Assert.Contains("trust=untrusted", report);
        Assert.Contains("── total ·", report);
    }

    [Fact]
    public void MaskingNeverTouchesThePromptSentToTheModel()
    {
        const string secret = "ghp_abcdefghijklmnopqrstuvwxyz012345";
        var assembled = PromptAssembly.Assemble(
            [new PromptSection("plugin_guidance", PromptTrust.Untrusted, secret)]);
        Assert.Contains(secret, assembled);
    }

    [Fact]
    public void CoreStatesTrustPrecedence()
    {
        var core = HerNessPrompt.Core("scope line", "tool line");
        Assert.Contains("scope line", core);
        Assert.Contains("tool line", core);
        Assert.Contains("Instruction priority", core);
        Assert.DoesNotContain("Clarification", core);
    }

    [Fact]
    public void CoreIncludesCompactResponseEconomyWithoutDroppingTechnicalContent()
    {
        var core = HerNessPrompt.Core("scope line", "tool line");

        Assert.Contains("Response economy", core);
        Assert.Contains("shorten prose, not required work", core);
        Assert.Contains("commands, errors, tests or evidence", core);
        Assert.Contains("state what remains", core);
        Assert.DoesNotContain("billing guarantee", core);
        Assert.Contains("Destructive/irreversible actions", core);
        Assert.Contains("exact code", core);
    }

    [Fact]
    public void CoreIncludesPerConversationResponseLanguageContractAndPriority()
    {
        var core = HerNessPrompt.Core("scope line", "tool line");
        var normalized = string.Join(" ", core.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

        Assert.Contains("Accuracy and language", normalized);
        Assert.Contains("latest human request's language", normalized);
        Assert.Contains("this conversation's last reliable response language", normalized);
        Assert.Contains("UI language, memory, tools and other chats", normalized);
        Assert.Contains("Explicit language requests win", normalized);
        Assert.Contains("for that response", normalized);
        Assert.Contains("last reliable response language", normalized);
        Assert.Contains("use English", normalized);

        var detected = normalized.IndexOf("latest human request's language", StringComparison.Ordinal);
        var explicitRequest = normalized.IndexOf("Explicit language requests win", StringComparison.Ordinal);
        var fallback = normalized.IndexOf("If the request is mixed", StringComparison.Ordinal);
        Assert.True(detected >= 0 && detected < explicitRequest && explicitRequest < fallback,
            "response-language priority order is not represented in the core prompt");
    }

    [Fact]
    public void CodexInstructionsMatchNativeWorkspaceTools()
    {
        var prompt = CodexInstructions.Default;
        var grepTool = ((char)96) + "grep_files" + (char)96;

        Assert.Contains(grepTool, prompt);
        Assert.DoesNotContain("There is no " + grepTool, prompt, StringComparison.Ordinal);
        Assert.DoesNotContain("other_chats", prompt, StringComparison.Ordinal);
        Assert.Contains("remember", prompt);
        Assert.Contains("update_plan", prompt);
        Assert.Contains("explore", prompt);
        Assert.Contains("install_plugin", prompt);
    }

    [Fact]
    public void CoreUsesQuestionToolForMissingTaskDetailsButAnswersInformationDirectly()
    {
        var core = HerNessPrompt.Core("scope line", "tool line");
        var normalized = System.Text.RegularExpressions.Regex.Replace(core, @"\s+", " ");

        Assert.Contains("Answer ordinary chat", normalized, StringComparison.Ordinal);
        Assert.Contains("through ask_user", normalized, StringComparison.Ordinal);
        Assert.Contains("A user's answer resumes the original task", normalized, StringComparison.Ordinal);
    }

    /// The canonical text ships to every platform, so it may not name a tool only one of
    /// them offers; a platform names its own tools in its own block.
    [Fact]
    public void CoreNamesNoPlatformOnlyTool()
    {
        var core = HerNessPrompt.Core("scope line", "tool line");

        foreach (var name in new[]
        {
            "update_plan", "install_plugin", "terminal_session",
            "ios_simulator", "computer_use", "browser_open",
        })
            Assert.DoesNotContain(name, core, StringComparison.Ordinal);
    }
}
