using MacAmbientJev.Protocol;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace MacAmbientJev.WinUI;

/// <summary>Status text whose typed recording tone selects theme-local template states.</summary>
public sealed class MainStatusText : Control
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(MainStatusText), new PropertyMetadata(string.Empty, OnTextChanged));
    // Object storage permits the not-yet-connected null tone from the presentation model.
    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(
        nameof(Tone), typeof(object), typeof(MainStatusText), new PropertyMetadata(null, OnToneChanged));
    public static readonly DependencyProperty MaxLinesProperty = DependencyProperty.Register(
        nameof(MaxLines), typeof(int), typeof(MainStatusText), new PropertyMetadata(0));
    public static readonly DependencyProperty TextWrappingProperty = DependencyProperty.Register(
        nameof(TextWrapping), typeof(TextWrapping), typeof(MainStatusText), new PropertyMetadata(TextWrapping.NoWrap));

    private bool templateApplied;

    public string? Text
    {
        get => (string?)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }
    public object? Tone
    {
        get => GetValue(ToneProperty);
        set => SetValue(ToneProperty, value);
    }
    public int MaxLines
    {
        get => (int)GetValue(MaxLinesProperty);
        set => SetValue(MaxLinesProperty, value);
    }
    public TextWrapping TextWrapping
    {
        get => (TextWrapping)GetValue(TextWrappingProperty);
        set => SetValue(TextWrappingProperty, value);
    }

    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        if (GetTemplateChild("StatusText") is not TextBlock)
            throw new InvalidOperationException("MainStatusTextStyle must contain a TextBlock named StatusText.");
        templateApplied = true;
        UpdateTone();
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new StatusTextAutomationPeer(this);

    private static void OnTextChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        var status = (MainStatusText)sender;
        if (string.IsNullOrEmpty(AutomationProperties.GetName(status)) &&
            FrameworkElementAutomationPeer.FromElement(status) is { } peer)
            peer.RaisePropertyChangedEvent(AutomationElementIdentifiers.NameProperty,
                args.OldValue ?? string.Empty, args.NewValue ?? string.Empty);
    }

    private static void OnToneChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((MainStatusText)sender).UpdateTone();

    private void UpdateTone()
    {
        var state = Tone switch
        {
            null or EngineRecordingTone.Neutral or EngineRecordingTone.Recording => "Secondary",
            EngineRecordingTone.Warning or EngineRecordingTone.Error => "Attention",
            _ => throw new ArgumentException("Recording tone is required for status text.", nameof(Tone))
        };
        if (templateApplied && !VisualStateManager.GoToState(this, state, false))
            throw new InvalidOperationException($"MainStatusTextStyle is missing the {state} visual state.");
    }

    private sealed class StatusTextAutomationPeer(MainStatusText owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override string GetClassNameCore() => nameof(MainStatusText);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
        protected override string GetNameCore()
        {
            var explicitName = base.GetNameCore();
            return string.IsNullOrEmpty(explicitName) ? owner.Text ?? string.Empty : explicitName;
        }
    }
}
