using System.Collections.Immutable;
using System.Globalization;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed record ShellTranscriptRowDetails(string SessionID, EngineID Revision, string RowID,
    EngineClauseState ClauseState, string ClauseStateText, ImmutableArray<string> SpeakerTexts);

public sealed partial class LiveViewModel
{
    /// <summary>
    /// Reads the engine's complete details for a displayed row. Callers should also guard their own
    /// flyout lifetime when awaiting this method.
    /// </summary>
    public async Task<RowDetailsRead<ShellTranscriptRowDetails>> ReadRowDetailsAsync(string rowID) =>
        await Context.Store.ReadRowDetailsAsync(rowID).ConfigureAwait(false) switch
        {
            RowDetailsRead<ShellRowDetails>.Read { Details: var details } => new RowDetailsRead<ShellTranscriptRowDetails>.Read(
                new ShellTranscriptRowDetails(details.SessionID, details.Revision, details.RowID, details.ClauseState,
                    details.ClauseStateText, details.Speakers.Select(span =>
                        $"{span.DisplayLabel} · {RowDetailTime(span.StartMS)}–{RowDetailTime(span.EndMS)}").ToImmutableArray())),
            RowDetailsRead<ShellRowDetails>.Superseded => new RowDetailsRead<ShellTranscriptRowDetails>.Superseded(),
            RowDetailsRead<ShellRowDetails>.Failed => new RowDetailsRead<ShellTranscriptRowDetails>.Failed(),
            var unknown => throw new InvalidOperationException($"Unsupported row details read: {unknown}.")
        };

    private static string RowDetailTime(long milliseconds) => string.Format(CultureInfo.InvariantCulture,
        "{0:00}:{1:00}", milliseconds / 60_000, milliseconds / 1_000 % 60);
}
