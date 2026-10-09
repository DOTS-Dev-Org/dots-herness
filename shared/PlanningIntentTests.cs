using System.Collections.Generic;
using System.Threading.Tasks;
using DotsHarnessCore;
using Xunit;

public sealed class PlanningIntentTests
{
    [Theory]
    [InlineData("Make a plan for adding OAuth")]
    [InlineData("Please plan the changes to src/App.swift")]
    [InlineData("Write the plan to plan.md")]
    [InlineData("Sadece sohbette plan yap")]
    [InlineData("Plan moduna geç")]
    [InlineData("Switch to plan mode")]
    [InlineData("Bu dosya için bir plan hazırla")]
    [InlineData("I need a plan for this file")]
    [InlineData("/plan add OAuth")]
    public void PlanningRequestsEnterPlanMode(string prompt)
    {
        Assert.True(PlanningIntent.IsPlanRequest(prompt), prompt);
    }

    [Theory]
    [InlineData("Apply the plan")]
    [InlineData("Planı uygula")]
    [InlineData("Approve plan")]
    [InlineData("Read plan.md")]
    [InlineData("Rename the plan file")]
    [InlineData("Explain what plan mode is")]
    public void ExecutionOrReferenceRequestsDoNotEnterPlanMode(string prompt)
    {
        Assert.False(PlanningIntent.IsPlanRequest(prompt), prompt);
    }

    [Theory]
    [InlineData("Bu dosyanın planını çıkar")]
    [InlineData("Make a planet texture")]
    [InlineData("Read plan.md")]
    [InlineData("Önce bunu planla")]
    public void WordsThatOnlyMentionAPlanAreAmbiguous(string prompt)
    {
        Assert.Equal(PlanVerdict.Ambiguous, PlanningIntent.Classify(prompt));
        Assert.False(PlanningIntent.IsPlanRequest(prompt), prompt);
    }

    [Fact]
    public async Task ResolveAsksTheModelOnlyForAmbiguousText()
    {
        var asked = new List<string>();
        Task<bool> Ask(string text) { asked.Add(text); return Task.FromResult(text.Contains("planını")); }

        Assert.True(await PlanningIntent.ResolveAsync("Make a plan for auth", Ask));
        Assert.False(await PlanningIntent.ResolveAsync("Fix the login bug", Ask));
        Assert.True(await PlanningIntent.ResolveAsync("Bu dosyanın planını çıkar", Ask));
        Assert.False(await PlanningIntent.ResolveAsync("Make a planet texture", Ask));
        Assert.Equal(new[] { "Bu dosyanın planını çıkar", "Make a planet texture" }, asked);
    }
}
