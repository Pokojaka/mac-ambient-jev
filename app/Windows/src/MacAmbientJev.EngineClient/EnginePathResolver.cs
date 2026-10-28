using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

[assembly: InternalsVisibleTo("MacAmbientJev.EngineClient.Tests")]

namespace MacAmbientJev.EngineClient;

public static class EnginePathResolver
{
    public static string Resolve() => Resolve(AppContext.BaseDirectory, RuntimeInformation.ProcessArchitecture);

    internal static string Resolve(string baseDirectory, Architecture architecture)
    {
        ushort expectedMachine;
        string expectedArchitecture;
        switch (architecture)
        {
            case Architecture.X64:
                expectedMachine = 0x8664;
                expectedArchitecture = "x64";
                break;
            case Architecture.Arm64:
                expectedMachine = 0xaa64;
                expectedArchitecture = "ARM64";
                break;
            default:
                throw new PlatformNotSupportedException(
                    $"Engine architecture '{architecture}' is unsupported; supported architectures are x64 and ARM64.");
        }

        var enginePath = Path.Combine(baseDirectory, "engine", "MacAmbientJevEngine.exe");
        BinaryReader reader;
        try
        {
            reader = new BinaryReader(new FileStream(enginePath, FileMode.Open, FileAccess.Read, FileShare.Read));
        }
        catch (IOException exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            throw new FileNotFoundException("The engine executable was not found.", enginePath, exception);
        }

        using (reader)
        {
            var stream = reader.BaseStream;
            if (stream.Length < 64 || reader.ReadUInt16() != 0x5a4d)
                throw new BadImageFormatException($"The engine executable has a truncated or invalid MZ header: '{enginePath}'.", enginePath);

            stream.Position = 0x3c;
            var peOffset = reader.ReadUInt32();
            if (peOffset < 64 || peOffset > stream.Length - 6)
                throw new BadImageFormatException($"The engine executable has an invalid PE header offset: '{enginePath}'.", enginePath);

            stream.Position = peOffset;
            if (reader.ReadUInt32() != 0x00004550)
                throw new BadImageFormatException($"The engine executable has an invalid PE signature: '{enginePath}'.", enginePath);

            var actualMachine = reader.ReadUInt16();
            if (actualMachine != expectedMachine)
            {
                var actualArchitecture = actualMachine switch
                {
                    0x014c => "x86",
                    0x8664 => "x64",
                    0xaa64 => "ARM64",
                    _ => $"unknown (0x{actualMachine:X4})"
                };
                throw new BadImageFormatException(
                    $"The engine architecture is {actualArchitecture}; expected {expectedArchitecture}. Path: '{enginePath}'.",
                    enginePath);
            }
        }

        return enginePath;
    }
}
