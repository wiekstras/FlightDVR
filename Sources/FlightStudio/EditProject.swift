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
            throw FFmpeg.ProcessError(command: "project",
                                      stderr: "This edit project uses an unsupported version.")
        }
        // A moved file can legitimately have a different path; the edit remains
        // useful, so warn through the UI only when loading actually fails.
        return project.edit
    }
}
