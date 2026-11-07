using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace MacAmbientJev.WinUI;

// Like the Mac idle processing icon, the idle indicator is hidden from assistive technology.
public sealed class ProcessingAccessibilityViewConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language) => value switch
    {
        null or EngineProcessingIndicator.Idle => Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw,
        EngineProcessingIndicator => Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Content,
        _ => throw new ArgumentException("Processing indicator is required.", nameof(value))
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

public sealed class ProcessingAccessibleNameConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language) => value switch
    {
        null or EngineProcessingIndicator.Idle => string.Empty,
        EngineProcessingIndicator.Running => "文字起こし処理中",
        EngineProcessingIndicator.Backlogged => "文字起こし待機中",
        EngineProcessingIndicator.Complete => "文字起こし完了",
        EngineProcessingIndicator.PartialFailure => "文字起こしに一部失敗",
        _ => throw new ArgumentException("Processing indicator is required.", nameof(value))
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

public sealed class IconGlyphConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language) => value switch
    {
        null => string.Empty,
        EngineRecordingTone.Neutral => "\uECCC",
        EngineRecordingTone.Recording => "\uE7C8",
        EngineRecordingTone.Warning => "\uE7BA",
        EngineRecordingTone.Error => "\uEA39",
        EngineProcessingIndicator.Idle => "\uECCA",
        EngineProcessingIndicator.Running => string.Empty,
        EngineProcessingIndicator.Backlogged => "\uE823",
        EngineProcessingIndicator.Complete => "\uE930",
        EngineProcessingIndicator.PartialFailure => "\uE7BA",
        ShellTranscriptBadgeKind.Live => "\uE704",
        ShellTranscriptBadgeKind.Finalizing or ShellTranscriptBadgeKind.ImportedProcessing => "\uE916",
        ShellTranscriptBadgeKind.Finalized => "\uE8FB",
        ShellTranscriptBadgeKind.Saved => "\uE8E4",
        ShellRecordingGlyph.Record => "\uE7C8",
        ShellRecordingGlyph.Stop => "\uE71A",
        _ => throw new ArgumentException($"Unsupported icon kind: {value}.", nameof(value))
    };

    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

public sealed class IconVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language)
    {
        if (targetType != typeof(Visibility)) throw new ArgumentException("Visibility is the only supported target type.", nameof(targetType));
        if (value is null) return Visibility.Collapsed;
        var visible = value switch
        {
            EngineRecordingTone tone => parameter switch
            {
                "RecordingSecondary" => tone == EngineRecordingTone.Neutral,
                "RecordingCritical" => tone is EngineRecordingTone.Recording or EngineRecordingTone.Error,
                "RecordingWarning" => tone == EngineRecordingTone.Warning,
                _ => throw new ArgumentException("Parameter must select a recording tone.", nameof(parameter))
            },
            EngineProcessingIndicator indicator => parameter switch
            {
                "ProcessingSecondary" => indicator is EngineProcessingIndicator.Idle or EngineProcessingIndicator.Complete,
                "ProcessingRunning" => indicator is EngineProcessingIndicator.Running,
                "ProcessingWarning" => indicator is EngineProcessingIndicator.Backlogged or EngineProcessingIndicator.PartialFailure,
                _ => throw new ArgumentException("Parameter must select a processing indicator tone.", nameof(parameter))
            },
            _ => throw new ArgumentException($"Unsupported icon visibility kind: {value}.", nameof(value))
        };
        return visible ? Visibility.Visible : Visibility.Collapsed;
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
