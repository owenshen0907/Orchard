import Foundation

public enum OrchardWorkspacePathError: Error, LocalizedError {
    case emptyRoot
    case absoluteRelativePath
    case escapedWorkspace

    public var errorDescription: String? {
        switch self {
        case .emptyRoot:
            return "工作区根路径不能为空。"
        case .absoluteRelativePath:
            return "相对路径不能是绝对路径。"
        case .escapedWorkspace:
            return "解析后的工作目录超出了已注册工作区的根路径。"
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
