using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;

namespace MacAmbientJev.EngineClient;

public sealed class ProcessEngineChild : IEngineChild
{
    private readonly Process _process;

    private ProcessEngineChild(Process process)
    {
        _process = process;
        Exit = WaitForExitAsync(process);
    }

    public Stream StandardInput => _process.StandardInput.BaseStream;
    public Stream StandardOutput => _process.StandardOutput.BaseStream;
    public Stream StandardError => _process.StandardError.BaseStream;
    public Task<int> Exit { get; }

    public static ProcessEngineChild Start(string enginePath, IReadOnlyList<string> arguments)
    {
        ArgumentException.ThrowIfNullOrEmpty(enginePath);
        if (!Path.IsPathFullyQualified(enginePath))
        {
            throw new ArgumentException("The engine path must be fully qualified.", nameof(enginePath));
        }

        if (!File.Exists(enginePath))
        {
            throw new FileNotFoundException("The engine file does not exist.", enginePath);
        }

        ArgumentNullException.ThrowIfNull(arguments);
        var startInfo = new ProcessStartInfo(enginePath)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        for (var index = 0; index < arguments.Count; index++)
        {
            string? argument = arguments[index];
            if (argument is null)
            {
                throw new ArgumentException("Arguments must not contain null elements.", nameof(arguments));
            }

            startInfo.ArgumentList.Add(argument);
        }

        var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException("Starting the engine process failed.");
            }

            return new ProcessEngineChild(process);
        }
        catch
        {
            process.Dispose();
            throw;
        }
    }

    public void Kill() => _process.Kill(entireProcessTree: true);

    public void Dispose() => _process.Dispose();

    private static async Task<int> WaitForExitAsync(Process process)
    {
        await process.WaitForExitAsync().ConfigureAwait(false);
        return process.ExitCode;
    }
}
