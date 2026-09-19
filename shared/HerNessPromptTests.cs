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
        Assert.Contains("tagged with a trust level", core);
        Assert.DoesNotContain("Clarification", core);
    }

    [Fact]
    public void CoreIncludesCompactResponseEconomyWithoutDroppingTechnicalContent()
    {
        var core = HerNessPrompt.Core("scope line", "tool line");

        Assert.Contains("Response economy", core);
        Assert.Contains("code blocks, commands, file paths, identifiers, API names", core);
        Assert.Contains("exact errors, and negative qualifiers unchanged", core);
        Assert.Contains("security warnings, irreversible confirmations", core);
        Assert.Contains("generated code, comments, commits, docs, PR text", core);
    }

    [Fact]
    public void CoreIncludesPerConversationResponseLanguageContractAndPriority()
    {
        var core = HerNessPrompt.Core("scope line", "tool line");
        var normalized = string.Join(" ", core.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

        Assert.Contains("Response language", normalized);
        Assert.Contains("latest human-authored user request", normalized);
        Assert.Contains("natural-language portion of the response only", normalized);
        Assert.Contains("current conversation", normalized);
        Assert.Contains("another conversation", normalized);
        Assert.Contains("remembered preference, project memory", normalized);
        Assert.Contains("application's interface language", normalized);
        Assert.Contains("Ignore code blocks, inline code, file paths, identifiers, URLs, quoted source", normalized);
        Assert.Contains("explicitly asks for a response in a named language", normalized);
        Assert.Contains("Re-evaluate the language on the next user turn", normalized);
        Assert.Contains("last reliable response language", normalized);
        Assert.Contains("answer in English", normalized);

        var detected = normalized.IndexOf("latest human-authored user request", StringComparison.Ordinal);
        var explicitRequest = normalized.IndexOf("explicitly asks for a response in a named language", StringComparison.Ordinal);
        var fallback = normalized.IndexOf("latest request is mixed", StringComparison.Ordinal);
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
        Assert.Contains("other_chats", prompt);
        Assert.Contains("remember", prompt);
        Assert.Contains("update_plan", prompt);
        Assert.Contains("explore", prompt);
        Assert.Contains("install_plugin", prompt);
    }
}
