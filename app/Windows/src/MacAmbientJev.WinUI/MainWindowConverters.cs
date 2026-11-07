using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace MacAmbientJev.WinUI;

// Product icons use explicit vector silhouettes, independent of the installed symbol font.
public sealed class MainGlyphConverter : IValueConverter
{
    private const string Circle = "M12,1 A11,11 0 1 1 12,23 A11,11 0 1 1 12,1 Z";
    private const string InnerCircle = "M12,3 A9,9 0 1 1 12,21 A9,9 0 1 1 12,3 Z";
    private const string Ring = "F0 " + Circle + " " + InnerCircle;
    private const string Record = Ring + " M12,7 A5,5 0 1 1 12,17 A5,5 0 1 1 12,7 Z";
    private const string Warning = "F0 M12,1 L24,23 H0 Z M11,8 H13 V16 H11 Z M11,18 H13 V20 H11 Z";
    private const string Error = "F0 M7,0 H17 L24,7 V17 L17,24 H7 L0,17 V7 Z M7,6 L12,11 L17,6 L18,7 L13,12 L18,17 L17,18 L12,13 L7,18 L6,17 L11,12 L6,7 Z";
    private const string Waveform = "M0,10 H2 V14 H0 Z M4,5 H6 V19 H4 Z M8,0 H10 V24 H8 Z M12,7 H14 V17 H12 Z M16,3 H18 V21 H16 Z M20,9 H22 V15 H20 Z";
    private const string Check = "M6,11 L10,15 L18,7 L19.5,8.5 L10,18 L4.5,12.5 Z";
    private const string Hourglass = "F0 M3,0 H21 V3 H19 V7 L14,12 L19,17 V21 H21 V24 H3 V21 H5 V17 L10,12 L5,7 V3 H3 Z M7,3 V6 L12,11 L17,6 V3 Z M7,18 V21 H17 V18 L12,13 Z";
    public object Convert(object? value, Type targetType, object? parameter, string language)
    {
        var data = value switch
        {
            null => "M0,0",
            EngineRecordingTone.Neutral => Circle,
            EngineRecordingTone.Recording => Record,
            EngineRecordingTone.Warning => Warning,
            EngineRecordingTone.Error => Error,
            EngineProcessingIndicator.Idle => Ring,
            EngineProcessingIndicator.Running => Waveform,
            EngineProcessingIndicator.Backlogged => Ring + " M11,5 H13 V11 H18 V13 H11 Z",
            EngineProcessingIndicator.Complete => Ring + " " + Check,
            EngineProcessingIndicator.PartialFailure => Warning,
            ShellTranscriptBadgeKind.Live => "M10,10 A2,2 0 1 1 14,14 A2,2 0 1 1 10,10 Z M7,6 L8.5,7.5 C6,10 6,14 8.5,16.5 L7,18 C3.5,14.5 3.5,9.5 7,6 Z M17,6 C20.5,9.5 20.5,14.5 17,18 L15.5,16.5 C18,14 18,10 15.5,7.5 Z M3,2 L4.5,3.5 C0,8 0,16 4.5,20.5 L3,22 C-2.5,16.5 -2.5,7.5 3,2 Z M21,2 C26.5,7.5 26.5,16.5 21,22 L19.5,20.5 C24,16 24,8 19.5,3.5 Z",
            ShellTranscriptBadgeKind.Finalizing or ShellTranscriptBadgeKind.ImportedProcessing => Hourglass,
            ShellTranscriptBadgeKind.Finalized => "F0 M12,0 L15,2 L19,2 L20,6 L23,9 L22,13 L23,17 L19,19 L17,23 L13,22 L9,23 L6,20 L2,19 L2,15 L0,12 L2,9 L2,5 L6,4 L9,1 Z " + InnerCircle + " " + Check,
            ShellTranscriptBadgeKind.Saved => "M0,3 H24 V5 H0 Z M0,8 H17 V10 H0 Z M0,13 H24 V15 H0 Z M0,18 H17 V20 H0 Z",
            ShellRecordingGlyph.Record => Record,
            ShellRecordingGlyph.Stop => "F0 " + Circle + " M8,8 H16 V16 H8 Z",
            _ => throw new ArgumentException($"Unsupported main window glyph: {value}.", nameof(value))
        };
        return Parse(data);
    }
    internal static Geometry Parse(string data) => ((Path)XamlReader.Load(
        $"<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='{data}' />")).Data;
    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

public sealed class MainBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language)
    {
        var key = parameter switch
        {
            "Text" => value switch
            {
                null or EngineRecordingTone.Neutral or EngineRecordingTone.Recording => "SecondaryTextBrush",
                EngineRecordingTone.Warning or EngineRecordingTone.Error => "TextFillColorPrimaryBrush",
                _ => throw new ArgumentException("Recording tone is required for status text.", nameof(value))
            },
            null => value switch
            {
                EngineRecordingTone.Recording or EngineRecordingTone.Error => "MacRedBrush",
                EngineRecordingTone.Warning or EngineProcessingIndicator.Backlogged or EngineProcessingIndicator.PartialFailure => "MacOrangeBrush",
                null or EngineRecordingTone.Neutral or EngineProcessingIndicator.Idle or EngineProcessingIndicator.Running or EngineProcessingIndicator.Complete => "SecondaryTextBrush",
                _ => throw new ArgumentException($"Unsupported main window tone: {value}.", nameof(value))
            },
            _ => throw new ArgumentException("Unknown brush converter parameter.", nameof(parameter))
        };
        return Application.Current.Resources[key];
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

public sealed class ProcessingRunningConverter : IValueConverter
{
    public bool AsVisibility { get; set; }
    public object Convert(object? value, Type targetType, object? parameter, string language)
    {
        if (value is not null and not EngineProcessingIndicator) throw new ArgumentException("Processing indicator is required.", nameof(value));
        var running = value is EngineProcessingIndicator.Running;
        return AsVisibility ? (running ? Visibility.Visible : Visibility.Collapsed) : running;
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

public sealed class TopSpacingConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language) => value is double spacing
        ? new Thickness(0, spacing, 0, 0) : throw new ArgumentException("Row spacing must be a double.", nameof(value));
    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

public sealed class FirstLineConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language) => value switch
    {
        null => string.Empty,
        string text => FirstLine(text),
        _ => throw new ArgumentException("Error text must be a string.", nameof(value))
    };
    internal static string FirstLine(string text)
    {
        var line = text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? string.Empty;
        // Exception names belong in the selectable details, not in the compact status row.
        var separator = line.IndexOf(':');
        if (separator > 0 && line[..separator].Trim().EndsWith("Exception", StringComparison.Ordinal))
            return line[(separator + 1)..].TrimStart();
        return line;
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}
