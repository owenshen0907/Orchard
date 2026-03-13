import Foundation

public enum OrchardWorkspaceLocator {
    public static func bestMatch(for path: String, workspaces: [WorkspaceDefinition]) -> WorkspaceDefinition? {
        let normalizedPath = normalize(path)

        return workspaces
            .filter { workspace in
                let rootPath = normalize(workspace.rootPath)
                return normalizedPath == rootPath || normalizedPath.hasPrefix(rootPath + "/")
            }
            .max { lhs, rhs in
                normalize(lhs.rootPath).count < normalize(rhs.rootPath).count
            }
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
