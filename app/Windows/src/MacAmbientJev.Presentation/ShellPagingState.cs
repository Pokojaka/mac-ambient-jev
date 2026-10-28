using System.Collections.Immutable;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public enum ShellPageMove { Reload, Next, Previous }

public sealed record ShellPageWindow<T> where T : class
{
    public ImmutableArray<T> Pages { get; init; } = ImmutableArray<T>.Empty;
    public int Index { get; init; } = -1;
    public T? Current => Index < 0 ? null : Pages[Index];

    internal ShellPageWindow<T> Apply(T page, ShellPageMove move)
    {
        ArgumentNullException.ThrowIfNull(page);
        switch (move)
        {
            case ShellPageMove.Reload:
                return this with { Pages = ImmutableArray.Create(page), Index = 0 };
            case ShellPageMove.Next:
            {
                var index = Index + 1;
                var pages = index < Pages.Length ? Pages.SetItem(index, page) : Pages.Add(page);
                if (pages.Length > 3) { pages = pages.RemoveAt(0); index--; }
                return this with { Pages = pages, Index = index };
            }
            case ShellPageMove.Previous:
            {
                var index = Index - 1;
                var pages = index >= 0 ? Pages.SetItem(index, page) : Pages.Insert(0, page);
                if (index < 0) index = 0;
                if (pages.Length > 3) pages = pages.RemoveAt(pages.Length - 1);
                return this with { Pages = pages, Index = index };
            }
            default:
                throw new ArgumentOutOfRangeException(nameof(move), move, "Unknown page move.");
        }
    }
}

public sealed record ShellTranscriptState
{
    public string? SessionID { get; init; }
    public EngineTranscriptPage? Tail { get; init; }
    public ShellPageWindow<EngineTranscriptPage> History { get; init; } = new();
    public bool HistoryStale { get; init; } = false;
    public bool Follow { get; init; } = true;
    public bool NewUpdatesAvailable { get; init; } = false;
}
