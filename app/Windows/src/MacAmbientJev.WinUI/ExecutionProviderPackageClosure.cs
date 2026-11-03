using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using MacAmbientJev.EngineClient;

namespace MacAmbientJev.WinUI;

internal static class ExecutionProviderPackageClosure
{
    private const uint PackageFilterHead = 0x10, PackageFilterDirect = 0x20;
    private const int ErrorInsufficientBuffer = 122, MaximumDllCount = 64, MaximumDirectoryCount = 16;

    internal static ExecutionProviderReadyResult.Ready Resolve(
        string packageFullName, string libraryPath, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageFullName);
        if (!Path.IsPathFullyQualified(libraryPath) || !Path.GetExtension(libraryPath).Equals(".dll", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The execution provider library path must be an absolute .dll path.");
        var requestedPath = Path.GetFullPath(libraryPath);
        HashSet<string> roots = new(StringComparer.OrdinalIgnoreCase), directoriesWithDlls = new(StringComparer.OrdinalIgnoreCase),
            basenames = new(StringComparer.OrdinalIgnoreCase);
        var inventory = new Dictionary<string, ExecutionProviderDependency>(StringComparer.OrdinalIgnoreCase);
        var pending = new Queue<string>(); pending.Enqueue(packageFullName);
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string? headRoot = null;
        while (pending.Count != 0) {
            cancellationToken.ThrowIfCancellationRequested();
            var name = pending.Dequeue();
            if (!visited.Add(name)) continue;
            var packages = QueryPackage(name);
            cancellationToken.ThrowIfCancellationRequested();
            foreach (var (fullName, root) in packages) {
                pending.Enqueue(fullName);
                if (fullName.Equals(packageFullName, StringComparison.OrdinalIgnoreCase)) headRoot = root;
                if (roots.Add(root)) InventoryRoot(root, inventory, basenames, directoriesWithDlls, cancellationToken);
            }
        }
        if (headRoot is null) throw new InvalidOperationException($"Package inventory did not return the requested head package '{packageFullName}'.");
        var relative = Path.GetRelativePath(headRoot, requestedPath);
        if (Path.IsPathRooted(relative) || relative == ".." || relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new InvalidOperationException($"The execution provider library '{requestedPath}' is outside head package '{packageFullName}'.");
        if (!inventory.TryGetValue(requestedPath, out var main)) throw new InvalidOperationException($"The execution provider library '{requestedPath}' is not present in the head package DLL inventory.");
        cancellationToken.ThrowIfCancellationRequested();
        var dependencies = inventory.Values.Where(file => !file.Path.Equals(main.Path, StringComparison.OrdinalIgnoreCase))
            .OrderBy(file => file.Path, StringComparer.OrdinalIgnoreCase)
            .ThenBy(file => file.Path, StringComparer.Ordinal).ToArray();
        return new ExecutionProviderReadyResult.Ready(main.Path, main.Hash, dependencies);
    }

    private static void InventoryRoot(string root, Dictionary<string, ExecutionProviderDependency> inventory,
        HashSet<string> basenames, HashSet<string> directoriesWithDlls, CancellationToken cancellationToken)
    {
        var directories = new Stack<string>(); directories.Push(root);
        while (directories.Count != 0) {
            cancellationToken.ThrowIfCancellationRequested();
            var directory = directories.Pop();
            var attributes = File.GetAttributes(directory);
            if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException($"Package inventory cannot include or traverse reparse point '{directory}'.");
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory)) {
                cancellationToken.ThrowIfCancellationRequested();
                var entryAttributes = File.GetAttributes(entry);
                if ((entryAttributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException($"Package inventory cannot include or traverse reparse point '{entry}'.");
                if ((entryAttributes & FileAttributes.Directory) != 0) { directories.Push(entry); continue; }
                if (!Path.GetExtension(entry).Equals(".dll", StringComparison.OrdinalIgnoreCase)) continue;
                var path = Path.GetFullPath(entry);
                if (inventory.ContainsKey(path)) continue;
                if (inventory.Count == MaximumDllCount) throw new InvalidOperationException($"Package DLL inventory exceeds the limit of {MaximumDllCount} files.");
                var basename = Path.GetFileName(path);
                if (basename.Equals("onnxruntime.dll", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException($"Package DLL inventory contains a forbidden ONNX Runtime library: '{path}'.");
                if (!basenames.Add(basename)) throw new InvalidOperationException($"Package DLL inventory contains different files named '{basename}'.");
                var parent = Path.GetDirectoryName(path)!;
                if (directoriesWithDlls.Add(parent) && directoriesWithDlls.Count > MaximumDirectoryCount)
                    throw new InvalidOperationException($"Package DLL inventory spans more than {MaximumDirectoryCount} directories.");
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
                inventory.Add(path, new(path, Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant()));
            }
        }
    }

    private static (string FullName, string Root)[] QueryPackage(string packageFullName)
    {
        var error = OpenPackageInfoByFullName(packageFullName, 0, out var reference);
        if (error != 0) throw new Win32Exception(error, $"OpenPackageInfoByFullName failed for package '{packageFullName}'.");
        try {
            uint bufferLength = 0;
            error = GetPackageInfo(reference, PackageFilterHead | PackageFilterDirect, ref bufferLength, IntPtr.Zero, out _);
            if (error == 0) throw new InvalidOperationException($"GetPackageInfo (size query) did not report the required buffer for '{packageFullName}'.");
            if (error != ErrorInsufficientBuffer) throw new Win32Exception(error, $"GetPackageInfo (size query) failed for package '{packageFullName}'.");
            if (bufferLength == 0 || bufferLength > int.MaxValue) throw new InvalidOperationException($"GetPackageInfo returned an invalid buffer size for '{packageFullName}'.");
            var buffer = Marshal.AllocHGlobal((int)bufferLength);
            try {
                error = GetPackageInfo(reference, PackageFilterHead | PackageFilterDirect, ref bufferLength, buffer, out var count);
                if (error != 0) throw new Win32Exception(error, $"GetPackageInfo failed for package '{packageFullName}'.");
                if (count == 0) throw new InvalidOperationException($"GetPackageInfo returned no packages for '{packageFullName}'.");
                var stride = Marshal.SizeOf<PackageInfoNative>();
                var packages = new (string FullName, string Root)[checked((int)count)];
                for (uint index = 0; index < count; index++) {
                    var info = Marshal.PtrToStructure<PackageInfoNative>(IntPtr.Add(buffer, checked((int)(index * (uint)stride))));
                    var fullName = Marshal.PtrToStringUni(info.PackageFullName);
                    var root = Marshal.PtrToStringUni(info.Path);
                    if (string.IsNullOrWhiteSpace(fullName) || string.IsNullOrWhiteSpace(root) || !Path.IsPathFullyQualified(root))
                        throw new InvalidOperationException($"GetPackageInfo returned an empty package name or non-absolute install root for '{packageFullName}'.");
                    packages[(int)index] = (fullName, Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)));
                }
                return packages;
            } finally { Marshal.FreeHGlobal(buffer); }
        } finally {
            error = ClosePackageInfo(reference);
            if (error != 0) throw new Win32Exception(error, $"ClosePackageInfo failed for package '{packageFullName}'.");
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PackageInfoNative {
        internal uint Reserved, Flags;
        internal IntPtr Path, PackageFullName, PackageFamilyName;
        internal PackageIdNative PackageId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PackageIdNative {
        internal uint Reserved, ProcessorArchitecture;
        internal ulong Version;
        internal IntPtr Name, Publisher, ResourceId, PublisherId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern int OpenPackageInfoByFullName(string packageFullName, uint reserved, out IntPtr packageInfoReference);
    [DllImport("kernel32.dll", ExactSpelling = true)] private static extern int GetPackageInfo(IntPtr packageInfoReference, uint flags, ref uint bufferLength, IntPtr buffer, out uint count);
    [DllImport("kernel32.dll", ExactSpelling = true)] private static extern int ClosePackageInfo(IntPtr packageInfoReference);
}
