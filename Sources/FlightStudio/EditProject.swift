import Foundation

/// A portable, human-readable edit sidecar. It references the original clip
/// rather than duplicating footage, so it is safe to keep beside DVR media or
/// share with another Flight Studio user.
struct EditProject: Codable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var sourcePath: String
    var edit: EditPlan
}

enum EditProjectError: LocalizedError, Equatable {
    case unsupportedVersion
    case wrongSource(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "This edit project uses an unsupported version."
        case .wrongSource(let filename):
            "This project belongs to \(filename). Select that recording before opening it."
        }
    }
}

enum EditProjectFile {
    static func encode(clip: Clip) throws -> Data {
        let project = EditProject(sourcePath: clip.url.path, edit: clip.edit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    static func decode(_ data: Data, for clip: Clip) throws -> EditPlan {
        let project = try JSONDecoder().decode(EditProject.self, from: data)
        guard project.version == EditProject.currentVersion else {
            throw EditProjectError.unsupportedVersion
        }
        let recordedSource = URL(fileURLWithPath: project.sourcePath).standardizedFileURL
        let selectedSource = clip.url.standardizedFileURL
        if recordedSource != selectedSource,
           FileManager.default.fileExists(atPath: recordedSource.path) {
            throw EditProjectError.wrongSource(recordedSource.lastPathComponent)
        }
        // If the recorded path is gone, the selected clip may be its renamed or
        // relocated source. Keep that recovery workflow available.
        return project.edit
    }
}
