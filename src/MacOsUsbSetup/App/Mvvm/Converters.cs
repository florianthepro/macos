using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace MacOsUsbSetup.App.Mvvm;

/// <summary>Collapses when the bound bool is true (inverse of the built-in converter).</summary>
public sealed class InverseBooleanToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is Visibility.Collapsed;
}
