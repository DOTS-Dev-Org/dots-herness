// Copyright (c) 2026 DOTS

using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public class PlanStepsToolTests
{
    [Fact]
    public void CurrentStepsReadsLatestPlanSinceUserMessage()
    {
        var output = PlanStepsTool.Execute("""{"steps":[{"title":"Read code","status":"done"},{"title":"Fix bug","status":"in_progress"},{"title":"Test","status":"pending"}]}""");
        var plan = new ChatMessage { Kind = ChatKind.Tool, Text = "✓ update_plan\n…", RawToolOutput = output };
        Assert.Equal(
            [new PlanStep("Read code", "done"), new PlanStep("Fix bug", "in_progress"), new PlanStep("Test", "pending")],
            PlanStepsTool.CurrentSteps([new ChatMessage { Kind = ChatKind.User, Text = "go" }, plan]));
        Assert.Empty(PlanStepsTool.CurrentSteps([plan, new ChatMessage { Kind = ChatKind.User, Text = "next" }]));
        Assert.StartsWith("The plan must", PlanStepsTool.Execute("""{"steps":[]}"""));
    }
}
