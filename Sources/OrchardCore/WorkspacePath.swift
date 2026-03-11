import Foundation

public enum OrchardWorkspacePathError: Error, LocalizedError {
    case emptyRoot
    case absoluteRelativePath
    case escapedWorkspace

    public var errorDescription: String? {
        switch self {
        case .emptyRoot:
            return "Workspace root path is empty."
        case .absoluteRelativePath:
            return "Relative path must not be absolute."
        case .escapedWorkspace:
            return "Resolved working directory escapes the registered workspace root."
        }
    }
}

public enum OrchardWorkspacePath {
    public static func resolve(rootPath: String, relativePath: String?) throws -> URL {
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty else {
            throw OrchardWorkspacePathError.emptyRoot
        }

        let rootURL = URL(fileURLWithPath: trimmedRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard let relativePath, !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rootURL
        }

        if relativePath.hasPrefix("/") {
            throw OrchardWorkspacePathError.absoluteRelativePath
        }

        let candidate = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        if candidate.path == rootURL.path || candidate.path.hasPrefix(rootURL.path + "/") {
            return candidate
        }

        throw OrchardWorkspacePathError.escapedWorkspace
    }
}
