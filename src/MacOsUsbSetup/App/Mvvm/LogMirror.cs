using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Threading;
using MacOsUsbSetup.Core.Diagnostics;

namespace MacOsUsbSetup.App.Mvvm;

/// <summary>
/// Mirrors <see cref="Log"/> output into an observable collection on the UI
/// thread for the duration of a running step. Dispose to detach.
/// </summary>
public sealed class LogMirror : IDisposable
{
    private const int MaxLines = 500;

    private readonly ObservableCollection<string> _target;
    private readonly Dispatcher _dispatcher;
    private readonly Action<string> _handler;

    public LogMirror(ObservableCollection<string> target)
    {
        _target = target;
        _dispatcher = Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        _handler = Append;
        Log.LineWritten += _handler;
    }

    private void Append(string line) => _dispatcher.BeginInvoke(() =>
    {
        _target.Add(line);
        while (_target.Count > MaxLines) _target.RemoveAt(0);
    });

    public void Dispose() => Log.LineWritten -= _handler;
}
