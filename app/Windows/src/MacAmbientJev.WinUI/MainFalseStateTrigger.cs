using Microsoft.UI.Xaml;

namespace MacAmbientJev.WinUI;

/// <summary>Enables a template state when a Boolean dependency property is false.</summary>
public sealed class MainFalseStateTrigger : StateTriggerBase
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(bool), typeof(MainFalseStateTrigger), new PropertyMetadata(false, OnValueChanged));

    public MainFalseStateTrigger() => SetActive(true);

    public bool Value
    {
        get => (bool)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    private static void OnValueChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((MainFalseStateTrigger)sender).SetActive(!(bool)args.NewValue);
}
