using MacAmbientJev.Presentation;

namespace MacAmbientJev.WinUI;

internal sealed class WindowsPathPicker : IPathPicker
{
    private readonly Microsoft.UI.Xaml.Window _owner;

    public WindowsPathPicker(Microsoft.UI.Xaml.Window owner)
    { ArgumentNullException.ThrowIfNull(owner); _owner = owner; }

    public async Task<string?> PickAudioFileAsync()
    {
        var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(_owner.AppWindow.Id)
        { Title = "音声ファイルを選択", FileTypeFilter = { ".wav", ".flac", ".mp3", ".m4a", ".aac" } };
        var file = await picker.PickSingleFileAsync();
        return file?.Path;
    }

    public async Task<string?> PickExportFolderAsync()
    {
        var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(_owner.AppWindow.Id)
        { Title = "書き出し先フォルダを選択", CommitButtonText = "選択" };
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }
}
