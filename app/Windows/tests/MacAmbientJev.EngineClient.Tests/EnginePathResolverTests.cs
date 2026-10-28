using System;
using System.Buffers.Binary;
using System.IO;
using System.Runtime.InteropServices;
using MacAmbientJev.EngineClient;
using Xunit;

namespace MacAmbientJev.EngineClient.Tests;

public sealed class EnginePathResolverTests
{
    private const string TempPrefix = "MacAmbientJev.EnginePathResolverTests-";

    [Fact]
    public void ResolveRequiresSupportedMatchingPeEngineAtFixedPath()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), TempPrefix + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        try
        {
            var engineDirectory = Path.Combine(tempRoot, "engine");
            Directory.CreateDirectory(engineDirectory);
            var enginePath = Path.Combine(engineDirectory, "MacAmbientJevEngine.exe");

            var unsupported = Assert.Throws<PlatformNotSupportedException>(
                () => EnginePathResolver.Resolve(tempRoot, Architecture.X86));
            Assert.Contains("x64 and ARM64", unsupported.Message, StringComparison.Ordinal);

            var missing = Assert.Throws<FileNotFoundException>(
                () => EnginePathResolver.Resolve(tempRoot, Architecture.X64));
            Assert.Equal(enginePath, missing.FileName);

            File.WriteAllBytes(enginePath, CreateFakePe(0x8664));
            Assert.Equal(enginePath, EnginePathResolver.Resolve(tempRoot, Architecture.X64));
            var opposite = Assert.Throws<BadImageFormatException>(
                () => EnginePathResolver.Resolve(tempRoot, Architecture.Arm64));
            Assert.Equal(enginePath, opposite.FileName);
            Assert.Contains("x64", opposite.Message, StringComparison.Ordinal);
            Assert.Contains("ARM64", opposite.Message, StringComparison.Ordinal);

            File.WriteAllBytes(enginePath, CreateFakePe(0xaa64));
            Assert.Equal(enginePath, EnginePathResolver.Resolve(tempRoot, Architecture.Arm64));

            File.WriteAllBytes(enginePath, new byte[] { 0x4d, 0x5a });
            var truncated = Assert.Throws<BadImageFormatException>(
                () => EnginePathResolver.Resolve(tempRoot, Architecture.X64));
            Assert.Equal(enginePath, truncated.FileName);
            Assert.Contains(enginePath, truncated.Message, StringComparison.Ordinal);

            var lowOffset = CreateFakePe(0x8664);
            BinaryPrimitives.WriteUInt32LittleEndian(lowOffset.AsSpan(0x3c), 63);
            File.WriteAllBytes(enginePath, lowOffset);
            Assert.Equal(enginePath, Assert.Throws<BadImageFormatException>(
                () => EnginePathResolver.Resolve(tempRoot, Architecture.X64)).FileName);

            var outsideOffset = CreateFakePe(0x8664);
            BinaryPrimitives.WriteUInt32LittleEndian(outsideOffset.AsSpan(0x3c), uint.MaxValue);
            File.WriteAllBytes(enginePath, outsideOffset);
            Assert.Equal(enginePath, Assert.Throws<BadImageFormatException>(
                () => EnginePathResolver.Resolve(tempRoot, Architecture.X64)).FileName);

            var badSignature = CreateFakePe(0x8664);
            BinaryPrimitives.WriteUInt32LittleEndian(badSignature.AsSpan(0x80), 0x12345678);
            File.WriteAllBytes(enginePath, badSignature);
            Assert.Equal(enginePath, Assert.Throws<BadImageFormatException>(
                () => EnginePathResolver.Resolve(tempRoot, Architecture.X64)).FileName);
        }
        finally
        {
            Directory.Delete(tempRoot, recursive: true);
        }
    }

    private static byte[] CreateFakePe(ushort machine)
    {
        const int peOffset = 0x80;
        var bytes = new byte[peOffset + 6];
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(0), 0x5a4d);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(0x3c), peOffset);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(peOffset), 0x00004550);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(peOffset + 4), machine);
        return bytes;
    }
}
