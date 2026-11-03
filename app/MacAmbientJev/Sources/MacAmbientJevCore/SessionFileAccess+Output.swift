import Foundation

extension SessionFileAccess {
    /// Writes a user-chosen output file. Symlinks in the parent directory path are resolved first,
    /// so the real parent becomes the pinned root. An output that is itself a symlink is an error.
    public static func writeOutputAtomically(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        try writeAtomically(data, to: parent.appending(path: url.lastPathComponent), relativeTo: parent)
    }
}
