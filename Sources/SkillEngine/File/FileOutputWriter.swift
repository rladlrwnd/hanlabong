import Foundation

/// 결과를 **원본 옆에 새 파일로** 저장한다. 원본은 절대 열어서 쓰지 않는다.
/// - 이름은 `원본이름` + suffix + `.확장자`. 이미 있으면 ` (1)`, ` (2)`… 를 붙여서 덮어쓰지 않는다.
/// - 임시 파일에 다 쓴 다음 이름을 바꿔치기해서, 중간에 멈춰도 반쯤 쓰인 파일이 남지 않는다.
/// - 출력 폴더는 항상 입력 파일이 있는 폴더다(밖으로 나가는 경로는 막는다).
public enum FileOutputWriter {
    /// 이미 만들어 둔 파일(영상 등 큰 결과)을 원본 옆으로 옮긴다. 이름 규칙·덮어쓰기 금지는 `save`와 같다.
    @discardableResult
    public static func save(movingFile source: URL, fileExtension: String, suffix: String, besideOriginal original: URL,
                            fileManager: FileManager = .default) throws -> URL {
        defer { try? fileManager.removeItem(at: source) }
        return try save(Data(), fileExtension: fileExtension, suffix: suffix, besideOriginal: original, fileManager: fileManager, movingFrom: source)
    }

    @discardableResult
    public static func save(_ data: Data, fileExtension: String, suffix: String, besideOriginal original: URL,
                            fileManager: FileManager = .default, movingFrom source: URL? = nil) throws -> URL {
        guard !suffix.contains("/"), !suffix.contains(".."), !fileExtension.contains("/") else {
            throw FileSkillError.unsafeOutputPath
        }
        let folder = original.deletingLastPathComponent().standardizedFileURL
        let base = original.deletingPathExtension().lastPathComponent

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: folder.path) else {
            throw FileSkillError.outputFolderNotWritable(folder.lastPathComponent)
        }

        let temporary = folder.appendingPathComponent(".\(base)\(suffix).\(UUID().uuidString).tmp")
        do {
            if let source { try fileManager.copyItem(at: source, to: temporary) } else { try data.write(to: temporary) }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw FileSkillError.outputFolderNotWritable(folder.lastPathComponent)
        }

        for index in 0..<1000 {
            let dot = fileExtension.isEmpty ? "" : ".\(fileExtension)"     // 확장자가 없으면 폴더(PDF 쪽 그림들)
            let name = index == 0 ? "\(base)\(suffix)\(dot)" : "\(base)\(suffix) (\(index))\(dot)"
            let destination = folder.appendingPathComponent(name)
            guard destination.deletingLastPathComponent().standardizedFileURL == folder, destination != original.standardizedFileURL else {
                continue
            }
            // moveItem은 이미 있는 파일 위로는 옮기지 않는다 → 덮어쓰기가 구조적으로 불가능하다
            do {
                try fileManager.moveItem(at: temporary, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw FileSkillError.outputFolderNotWritable(folder.lastPathComponent)
            }
        }
        try? fileManager.removeItem(at: temporary)
        throw FileSkillError.unsafeOutputPath
    }
}

/// 한 파일을 스킬로 변환해서 원본 옆에 저장하는 한 번의 작업.
public enum FileJob {
    public static func run(_ skill: FileSkill, input: URL, executor: FileSkillExecutor = FileSkillExecutor()) throws -> URL {
        let result = try executor.run(skill, input: input)
        if let file = result.fileURL {
            return try FileOutputWriter.save(movingFile: file, fileExtension: result.fileExtension, suffix: skill.output.suffix, besideOriginal: input)
        }
        return try FileOutputWriter.save(result.data, fileExtension: result.fileExtension, suffix: skill.output.suffix, besideOriginal: input)
    }
}
