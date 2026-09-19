// Copyright (c) 2026 DOTS

using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;

namespace DotsHarnessCore;

/// <summary>
/// UI-only view over a conversation's messages: shows the newest <see cref="PageSize"/>
/// items and pages older ones in when the user scrolls up. The agent reads the full
/// source collection, so model context never changes because of this window.
/// </summary>
public sealed class MessageTail<T> : ObservableCollection<T>, IDisposable
{
    public const int PageSize = 10;
    private readonly ObservableCollection<T> _source;
    private int _hidden;

    public MessageTail(ObservableCollection<T> source)
    {
        _source = source;
        _hidden = Math.Max(0, source.Count - PageSize);
        for (var i = _hidden; i < source.Count; i++) Items.Add(source[i]);
        source.CollectionChanged += OnSourceChanged;
    }

    public ObservableCollection<T> Source => _source;
    public bool HasOlder => _hidden > 0;

    /// <summary>Prepends up to one page of older messages. Returns false when none are left.</summary>
    public bool LoadOlder()
    {
        if (_hidden == 0) return false;
        var start = Math.Max(0, _hidden - PageSize);
        for (var i = _hidden - 1; i >= start; i--) InsertItem(0, _source[i]);
        _hidden = start;
        return true;
    }

    public void Dispose() => _source.CollectionChanged -= OnSourceChanged;

    private void OnSourceChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        // Common path: streaming/new turns append at the end.
        if (e.Action == NotifyCollectionChangedAction.Add
            && e.NewItems is { } added
            && e.NewStartingIndex == _source.Count - added.Count)
        {
            foreach (T item in added) InsertItem(Count, item);
            return;
        }
        // Anything else (remove, replace, move, reset): rebuild, keeping how far back the user has paged.
        var visible = Math.Min(_source.Count, Math.Max(Count, PageSize));
        _hidden = _source.Count - visible;
        Items.Clear();
        for (var i = _hidden; i < _source.Count; i++) Items.Add(_source[i]);
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Count)));
        OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
        OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
    }
}
