using MacAmbientJev.EngineClient;

namespace MacAmbientJev.Engine.Tests;

internal sealed class NoopEngineObserver : IEngineObserver
{
    public void EngineStarted(string enginePath, int processId) { }
    public void EngineStderrLine(string line) { }
    public void EngineExited(int exitCode) { }
    public void ClientFailed(EngineClientFailure failure) { }
}
