using System.Reflection;
using System.Runtime.Versioning;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed class PortableAssemblyTests
{
    [Fact]
    public void LibraryTargetsPortableNet10()
    {
        var assembly = Assembly.Load("MacAmbientJev.Presentation");
        var targetFramework = assembly.GetCustomAttribute<TargetFrameworkAttribute>();

        Assert.NotNull(targetFramework);
        Assert.Equal(".NETCoreApp,Version=v10.0", targetFramework!.FrameworkName);
        Assert.Null(assembly.GetCustomAttribute<TargetPlatformAttribute>());
    }
}
