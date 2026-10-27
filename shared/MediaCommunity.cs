// Copyright (c) 2026 DOTS
// Media community: canvases other people shared, read from the public feed.
// Mirrors MediaCommunity.swift on macOS.

using System.Text.Json;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed class MediaCommunityPost
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string Author { get; set; } = "";
    public string Category { get; set; } = "";
    public int Likes { get; set; }
    public MediaCanvas Canvas { get; set; } = new();
}

public sealed class MediaCommunityClient
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly string _cachePath;

    public MediaCommunityClient(MarketplaceSession session, string cachePath)
    {
        Session = session;
        _cachePath = cachePath;
        try { if (File.Exists(cachePath)) Posts = DecodeFeed(File.ReadAllText(cachePath)); }
        catch (IOException) { }
    }

    public MarketplaceSession Session { get; }
    public List<MediaCommunityPost> Posts { get; private set; } = [];
    public bool IsLoading { get; private set; }
    public event Action? Changed;

    /// <summary>One unreadable post is dropped instead of emptying the feed.</summary>
    public static List<MediaCommunityPost> DecodeFeed(string json)
    {
        JsonArray? posts;
        try { posts = JsonNode.Parse(json)?["posts"] as JsonArray; }
        catch (JsonException) { return []; }
        var found = new List<MediaCommunityPost>();
        foreach (var node in posts ?? [])
        {
            try
            {
                if (node?.Deserialize<MediaCommunityPost>(MediaStudioJson.Options) is { Canvas.Width: > 0, Canvas.Height: > 0 } post && post.Id.Length > 0)
                {
                    post.Canvas = post.Canvas.CommunityCopy();
                    found.Add(post);
                }
            }
            catch (JsonException) { }
        }
        return found;
    }

    public async Task RefreshAsync()
    {
        if (IsLoading) return;
        IsLoading = true;
        Changed?.Invoke();
        try
        {
            // Read from the API host: the dots.net.tr/harness route does not reach the worker.
            using var request = new HttpRequestMessage(HttpMethod.Get, MarketplaceSession.DefaultApiBase + "harness/media-community.json");
            request.Headers.UserAgent.ParseAdd("DotsHarness");
            using var response = await Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return;
            var json = await response.Content.ReadAsStringAsync();
            Posts = DecodeFeed(json);
            Directory.CreateDirectory(Path.GetDirectoryName(_cachePath)!);
            await File.WriteAllTextAsync(_cachePath, json);
        }
        catch (HttpRequestException) { }
        catch (TaskCanceledException) { }
        catch (IOException) { }
        finally
        {
            IsLoading = false;
            Changed?.Invoke();
        }
    }

    /// <summary>Sends a canvas for review; it joins the feed once an admin approves it.</summary>
    public Task ShareAsync(MediaCanvas canvas, string title, string category) =>
        SendAsync("api/media/community", JsonSerializer.SerializeToUtf8Bytes(new JsonObject
        {
            ["title"] = title.Length > 80 ? title[..80] : title,
            ["category"] = category,
            ["canvas"] = JsonSerializer.SerializeToNode(canvas.CommunityCopy(), MediaStudioJson.Options),
        }));

    /// <summary>Counts the like on the server when signed in; the saved list itself stays on this device.</summary>
    public async Task SetLikedAsync(bool liked, string postId)
    {
        if (!Session.IsSignedIn) return;
        try
        {
            var data = await SendAsync($"api/media/community/{Uri.EscapeDataString(postId)}/like",
                JsonSerializer.SerializeToUtf8Bytes(new { liked }));
            if (JsonNode.Parse(data)?["likes"] is JsonValue value && value.TryGetValue<int>(out var likes)
                && Posts.FirstOrDefault(p => p.Id == postId) is { } post)
            {
                post.Likes = likes;
                Changed?.Invoke();
            }
        }
        catch (Exception) { }
    }

    private async Task<byte[]> SendAsync(string path, byte[] body)
    {
        var result = await Session.AuthorizedDataAsync(path, HttpMethod.Post, body, "application/json");
        if ((int)result.StatusCode is < 200 or >= 300)
            throw new MarketplaceSessionException(result.StatusCode, System.Text.Encoding.UTF8.GetString(result.Data));
        return result.Data;
    }
}
