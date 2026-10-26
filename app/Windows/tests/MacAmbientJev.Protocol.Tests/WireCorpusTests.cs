using System;
using System.IO;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class WireCorpusTests
{
    [Fact]
    public void LinkedWireCorpusIsReadableAndHasDocumentedRecordCount()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "wire-v1.ndjson");
        var records = File.ReadAllLines(path, new System.Text.UTF8Encoding(false, true));

        // The count matches the independent wire example corpus documented in docs/windows.md.
        Assert.NotEmpty(records);
        Assert.Equal(102, records.Length);
        Assert.All(records, record => Assert.False(string.IsNullOrWhiteSpace(record)));
    }
}
