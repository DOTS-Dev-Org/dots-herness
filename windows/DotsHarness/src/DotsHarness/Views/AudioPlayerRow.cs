// Copyright (c) 2026 DOTS
// An inline audio player for a generated sound: play/pause, a seek bar and the
// time. Mirrors the macOS InlineAudioPlayer; when the platform codec is
// missing the file goes to the system player instead.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

/// <summary>One audio file with its own player.</summary>
public sealed class AudioPlayerRow : UserControl
{
    private readonly Button _play = new() { Content = "▶", Width = 28, Height = 28, Padding = new Thickness(0) };
    private readonly Slider _seek = new() { Width = 110, Minimum = 0, Maximum = 1, Value = 0, IsEnabled = false, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
    private readonly TextBlock _time = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(200) };
    private MediaPlayer? _player;
    private string? _path;
    private TimeSpan _duration;
    private bool _seeking;
    private bool _playing;

    public AudioPlayerRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(_play);
        row.Children.Add(_seek);
        row.Children.Add(_time);
        Content = row;
        _play.Click += (_, _) => Toggle();
        _seek.ValueChanged += OnSeek;
        _timer.Tick += (_, _) => Refresh();
        _time.Text = "0:00";
    }

    /// <summary>The file to play. Setting it resets the player.</summary>
    public string Path
    {
        get => _path ?? "";
        set
        {
            if (_path == value) return;
            _path = value;
            _duration = TimeSpan.Zero;
            _seek.Value = 0;
            _seek.IsEnabled = false;
            _time.Text = "0:00";
            _play.Content = "▶";
            Stop();
        }
    }

    private void Toggle()
    {
        var path = Path;
        if (string.IsNullOrWhiteSpace(path) || !System.IO.File.Exists(path))
        {
            AudioPlayback.OpenExternally(path);
            return;
        }
        if (_player is null)
        {
            _player = new MediaPlayer();
            _player.MediaOpened += (_, _) =>
            {
                _duration = _player?.NaturalDuration.HasTimeSpan == true ? _player.NaturalDuration.TimeSpan : TimeSpan.Zero;
                _seek.IsEnabled = _duration > TimeSpan.Zero;
                Dispatcher.Invoke(() => Refresh());
            };
            _player.MediaFailed += (_, _) =>
            {
                // The platform codec is missing: hand the file to the system player.
                Dispatcher.BeginInvoke(() => AudioPlayback.OpenExternally(path));
            };
            _player.Open(new Uri(path));
        }
        if (_playing)
        {
            _player.Pause();
            _playing = false;
            _play.Content = "▶";
            _timer.Stop();
        }
        else
        {
            _player.Play();
            _playing = true;
            _play.Content = "■";
            _timer.Start();
        }
    }

    private void Refresh()
    {
        if (_player is null || _duration <= TimeSpan.Zero) return;
        var position = _player.Position;
        if (!_seeking) _seek.Value = Math.Clamp(position.TotalSeconds / _duration.TotalSeconds, 0, 1);
        _time.Text = $"{Format(position)} / {Format(_duration)}";
    }

    private void OnSeek(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_player is null || _duration <= TimeSpan.Zero) return;
        if (Math.Abs(e.NewValue - e.OldValue) < 0.0001) return;
        _seeking = true;
        _player.Position = TimeSpan.FromSeconds(e.NewValue * _duration.TotalSeconds);
        _seeking = false;
    }

    private void Stop()
    {
        _timer.Stop();
        _playing = false;
        if (_player is null) return;
        _player.Stop();
        _player.Close();
        _player = null;
    }

    private static string Format(TimeSpan value) =>
        $"{(int)value.TotalMinutes}:{value.Seconds:00}";
}
