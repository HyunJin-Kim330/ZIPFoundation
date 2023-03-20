//
//  FileManager+ZIP.swift
//  ZIPFoundation
//
//  Copyright © 2017-2023 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

extension FileManager {
    typealias CentralDirectoryStructure = Entry.CentralDirectoryStructure
    typealias VoidVoidClosure = () -> Void
    /// Zips the file or directory contents at the specified source URL to the destination URL.
    ///
    /// If the item at the source URL is a directory, the directory itself will be
    /// represented within the ZIP `Archive`. Calling this method with a directory URL
    /// `file:///path/directory/` will create an archive with a `directory/` entry at the root level.
    /// You can override this behavior by passing `false` for `shouldKeepParent`. In that case, the contents
    /// of the source directory will be placed at the root of the archive.
    /// - Parameters:
    ///   - sourceURL: The file URL pointing to an existing file or directory.
    ///   - destinationURL: The file URL that identifies the destination of the zip operation.
    ///   - shouldKeepParent: Indicates that the directory name of a source item should be used as root element
    ///                       within the archive. Default is `true`.
    ///   - compressionMethod: Indicates the `CompressionMethod` that should be applied.
    ///                        By default, `zipItem` will create uncompressed archives.
    ///   - progress: A progress object that can be used to track or cancel the zip operation.
    /// - Throws: Throws an error if the source item does not exist or the destination URL is not writable.
    public func zipItem(at sourceURL: URL, to destinationURL: URL,
                        shouldKeepParent: Bool = true, compressionMethod: CompressionMethod = .none,
                        progress: Progress? = nil, completionHandler: @escaping ((Error?)->Void)) throws {
        let fileManager = FileManager()
        var error: Error
    
        // 압축하고자 하는 파일이 주어진 경로에 없을 때
        guard fileManager.itemExists(at: sourceURL) else {
            error = CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
            return completionHandler(error)
        }
        
        // 이미 압축하고자 하는 파일명과 동일한 파일이 존재할 때
        guard !fileManager.itemExists(at: destinationURL) else {
            error = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destinationURL.path])
            return completionHandler(error)
        }
        
        // 아카이브를 만들 수 없을 때
        guard let archive = Archive(url: destinationURL, accessMode: .create) else {
            if errno == 28 {  // 아카이브조차 만들 수 없을 때 용량부족에러이면 posixError로 변환하여 던진다
                error = POSIXError.init(28, path: "")
                return completionHandler(error)
            }
            error = Archive.ArchiveError.unwritableArchive
            return completionHandler(error)
        }
        let isDirectory = try FileManager.typeForItem(at: sourceURL) == .directory
        if isDirectory {
            var subPaths = try self.subpathsOfDirectory(atPath: sourceURL.path)
            // Enforce an entry for the root directory to preserve its file attributes
            if shouldKeepParent { subPaths.append("") }
            var totalUnitCount = Int64(0)
            if let progress = progress {
                totalUnitCount = subPaths.reduce(Int64(0), {
                    let itemURL = sourceURL.appendingPathComponent($1)
                    let itemSize = archive.totalUnitCountForAddingItem(at: itemURL)
                    return $0 + itemSize
                })
                progress.totalUnitCount = totalUnitCount
            }

            // If the caller wants to keep the parent directory, we use the lastPathComponent of the source URL
            // as common base for all entries (similar to macOS' Archive Utility.app)
            let directoryPrefix = sourceURL.lastPathComponent
            for entryPath in subPaths {
                let finalEntryPath = shouldKeepParent ? directoryPrefix + "/" + entryPath : entryPath
                let finalBaseURL = shouldKeepParent ? sourceURL.deletingLastPathComponent() : sourceURL
                if let progress = progress {
                    let itemURL = sourceURL.appendingPathComponent(entryPath)
                    let entryProgress = archive.makeProgressForAddingItem(at: itemURL)
                    progress.addChild(entryProgress, withPendingUnitCount: entryProgress.totalUnitCount)
                    try archive.addEntry(with: finalEntryPath, relativeTo: finalBaseURL,
                                         compressionMethod: compressionMethod, progress: entryProgress)
                } else {
                    try archive.addEntry(with: finalEntryPath, relativeTo: finalBaseURL,
                                         compressionMethod: compressionMethod)
                }
            }
        } else {
            progress?.totalUnitCount = archive.totalUnitCountForAddingItem(at: sourceURL)
            let baseURL = sourceURL.deletingLastPathComponent()
            try archive.addEntry(with: sourceURL.lastPathComponent, relativeTo: baseURL,
                                 compressionMethod: compressionMethod, progress: progress)
        }
        return completionHandler(nil)
    }

    /// Unzips the contents at the specified source URL to the destination URL.
    ///
    /// - Parameters:
    ///   - sourceURL: The file URL pointing to an existing ZIP file.
    ///   - destinationURL: The file URL that identifies the destination directory of the unzip operation.
    ///   - skipCRC32: Optional flag to skip calculation of the CRC32 checksum to improve performance.
    ///   - progress: A progress object that can be used to track or cancel the unzip operation.
    ///   - preferredEncoding: Encoding for entry paths. Overrides the encoding specified in the archive.
    /// - Throws: Throws an error if the source item does not exist or the destination URL is not writable.
    ///
    ///    zip파일의 종류는 3가지가 있습니다.
    ///    1. 파일이나 폴더가 오직 하나만 있는 압축파일
    ///    2. 폴더 하나밑에 여러가지 파일 및 폴더가 있는 압축파일
    ///    3. 최상위 트리가 없고 그냥 여러 가지 파일 및 폴더가 압축된 압축파일
    ///
    ///    특정 압축파일의 Archive를 생성하면 그 안의 모든 파일 및 폴더가 배열형태로 저장된 entries를 반환합니다.
    ///    C언어 기반 라이브러리를 쓰고 있기 때문에 '__MACOSX'폴더와 같은 메타정보들이 자동으로 생겨납니다. 구글링 결과 이들을 삭제해도 아무 이상 없다는 판단을 하게 되었습니다.
    ///
    ///
    ///
    
    public func unzipItem(at sourceURL: URL, to destinationURL: URL, skipCRC32: Bool = false,
                   progress: Progress? = nil, preferredEncoding: String.Encoding? = nil, completionHandler: @escaping (() -> Void ) ) throws -> (() -> Void) {
        let fileManager = FileManager()
        var createdList: [URL] = []  // 용량 부족 에러발생 시 생성되었던 모든 파일을 지우기 위해
        
        guard fileManager.itemExists(at: sourceURL) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        guard let archive = Archive(url: sourceURL, accessMode: .read, preferredEncoding: preferredEncoding) else {
            throw Archive.ArchiveError.unreadableArchive
        }

        var totalUnitCount = Int64(0)
        
        let entries: [Entry] = deletingMeta(archive: archive, preferredEncoding: preferredEncoding)
        
        if let progress = progress {
            totalUnitCount = entries.reduce(0, { $0 + archive.totalUnitCountForReading($1) })
            progress.totalUnitCount = totalUnitCount
        }
        
        // 폴더만들기
        var newSourceURL = sourceURL.deletingLastPathComponent()
        var oneFolderDownName: String = ""
        if entries.count >= 2 {
            // 2번 유형의 압축파일인지 검사
            if isOneFolderDown(entries: entries, preferredEncoding: preferredEncoding) {
                // 엔트리 경로를 다 바꿔줘야됨, 폴더생성아님
                oneFolderDownName = getFirstName(entries, preferredEncoding: preferredEncoding)
                if fileManager.fileExists(atPath: destinationURL.path + "/\(oneFolderDownName)") {
                    oneFolderDownName = getSaveLocationName(path: destinationURL.path + "/\(oneFolderDownName)")
                }
            } else {
                //중복검사
                var folderName = sourceURL.deletingPathExtension().lastPathComponent
                if fileManager.fileExists(atPath: sourceURL.deletingPathExtension().path) {
                    folderName = getSaveLocationName(path: sourceURL.path)
                }
                newSourceURL = appendingURL(origin: newSourceURL, component: folderName)
                do {
                    try fileManager.createDirectory(at: newSourceURL, withIntermediateDirectories: true)
                    createdList.append(newSourceURL)
                } catch {
                    print(error)
                }
            }
        }

        for entry in entries {
            var path = preferredEncoding == nil ? entry.path : entry.path(using: preferredEncoding!)
            var entryURL = destinationURL // 여기서 이름 다르게 주면 정상적으로 저장됨

            if entries.count >= 2 {
                if isOneFolderDown(entries: entries, preferredEncoding: preferredEncoding) {
                    path = changeEntryPath(entry: entry, folderName: oneFolderDownName, preferredEncoding: preferredEncoding)
                    entryURL = appendingURL(origin: entryURL, component: path)
                    createdList.append(entryURL)
                } else {
                    entryURL = appendingURL(origin: newSourceURL, component: path)
                }
            } else { // 원소가 하나일때
                let fileExtension = getUrl(path: path).pathExtension
                let fileURL = appendingURL(origin: destinationURL, component: path)
                if fileManager.fileExists(atPath: fileURL.path) {
                    let newFileName = getSaveLocationName(path: fileURL.path)
                    entryURL = appendingURL(origin: entryURL, component: newFileName).appendingPathExtension(fileExtension)
                } else {
                    entryURL = fileURL
                }
            }
            
            guard entryURL.isContained(in: destinationURL) else {
                throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: entryURL.path])
            }
            let crc32: CRC32
            
            do {
                if let progress {
                    let entryProgress = archive.makeProgressForReading(entry)
                    progress.addChild(entryProgress, withPendingUnitCount: entryProgress.totalUnitCount)
                    crc32 = try archive.extract(entry, to: entryURL, skipCRC32: skipCRC32, progress: entryProgress)
                    //print(progress.fileCompletedCount)
                } else {
                    crc32 = try archive.extract(entry, to: entryURL, skipCRC32: skipCRC32)
                }
            } catch {
                let err = error as NSError
                
                if err.code == 28 { // 용량 부족 에러이면 생성되었던 파일을 삭제한다.
                    for file in createdList {
                        if fileManager.fileExists(atPath: file.path) {
                            try fileManager.removeItem(at: file)
                        }
                    }
                }
                throw err
            }

            func verifyChecksumIfNecessary() throws {
                if skipCRC32 == false, crc32 != entry.checksum {
                    throw Archive.ArchiveError.invalidCRC32
                }
            }
            try verifyChecksumIfNecessary()
        }
        return completionHandler
    }
    
    func getSaveLocationName(path: String, fileNumber: Int = 2) -> String {
        let url = getUrl(path: path)
        let urlExtension = url.pathExtension
        var temp = url.deletingPathExtension().path + " \(fileNumber)"
           if urlExtension != "" && urlExtension != "zip" {
            temp.append(".\(urlExtension)")
        }
        
        if FileManager.default.fileExists(atPath: temp) {
            return getSaveLocationName(path: path, fileNumber: fileNumber + 1)
        } else {
            return getUrl(path: temp).deletingPathExtension().lastPathComponent
        }
    }
    
    func deletingMeta(archive: Archive, preferredEncoding: String.Encoding? = nil) -> [Entry] {
        var entries: [Entry] = []
        
        for entry in archive {
            let path = preferredEncoding == nil ? entry.path : entry.path(using: preferredEncoding!)
            
            if path.contains("__MACOSX") || path.contains(".DS_Store"){
                continue
            }
            entries.append(entry)
        }
        return entries
    }
    
    // 2번 유형의 압축파일인지 검사하는 함수
    func isOneFolderDown(entries: [Entry], preferredEncoding: String.Encoding? = nil) -> Bool {
        var componentNum: [Int] = []
        
        for entry in entries {
            let path = preferredEncoding == nil ? entry.path : entry.path(using: preferredEncoding!)
            let url = getUrl(path: path)
            componentNum.append(url.pathComponents.count)
        }
        componentNum.sort()
        
        if componentNum[0] == componentNum[1] {
            return false
        } else {
            return true
        }
    }
    
    // 2번 유형의 압축파일에서 모든 엔트리 경로의 첫 번째 이름을 바꿔줘야 함
    func changeEntryPath(entry: Entry, folderName: String, preferredEncoding: String.Encoding? = nil) -> String {
        var path = preferredEncoding == nil ? entry.path : entry.path(using: preferredEncoding!)
        let firstIndex =  path.firstIndex(of: "/")!
        path = String(path[firstIndex...])
        path = folderName + path
        return path
    }
    
    func getFirstName(_ entries: [Entry], preferredEncoding: String.Encoding? = nil) -> String {
        var paths: [String] = []
        var componentNum: [Int] = []

        for entry in entries {
            let path = preferredEncoding == nil ? entry.path : entry.path(using: preferredEncoding!)
            paths.append(path)

            let url = getUrl(path: path)
            componentNum.append(url.pathComponents.count)
            //print(url.pathComponents)
        }

        let min = componentNum.min()!
        let index = componentNum.firstIndex(of: min)!
        return paths[index].replacingOccurrences(of: "/", with: "")
    }
    
    func appendingURL(origin: URL, component: String) -> URL {
        if #available(macOS 13.0, *) {
            return origin.appending(components: component)
        } else {
            return origin.appendingPathComponent(component)
        }
    }
    
    func getUrl(path: String) -> URL {
        if #available(macOS 13.0, *) {
            return URL(filePath: path)
        } else {
            return URL(fileURLWithPath: path)
        }
    }
    
    func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()

        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/zsh"
        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)!

        return output
    }

    // MARK: - Helpers

    func itemExists(at url: URL) -> Bool {
        // Use `URL.checkResourceIsReachable()` instead of `FileManager.fileExists()` here
        // because we don't want implicit symlink resolution.
        // As per documentation, `FileManager.fileExists()` traverses symlinks and therefore a broken symlink
        // would throw a `.fileReadNoSuchFile` false positive error.
        // For ZIP files it may be intended to archive "broken" symlinks because they might be
        // resolvable again when extracting the archive to a different destination.
        return (try? url.checkResourceIsReachable()) == true
    }

    func createParentDirectoryStructure(for url: URL) throws {
        let parentDirectoryURL = url.deletingLastPathComponent()
        try self.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    func transferAttributes(from entry: Entry, toItemAtURL url: URL) throws {
        let attributes = FileManager.attributes(from: entry)
        switch entry.type {
        case .directory, .file:
            try self.setAttributes(attributes, ofItemAtURL: url)
        case .symlink:
            try self.setAttributes(attributes, ofItemAtURL: url, traverseLink: false)
        }
    }

    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtURL url: URL, traverseLink: Bool = true) throws {
        // `FileManager.setAttributes` traverses symlinks and applies the attributes to
        // the symlink destination. Since we want to be able to create symlinks where
        // the destination isn't available (yet), we want to directly apply entry attributes
        // to the symlink (vs. the destination file).
        guard traverseLink == false else {
            try self.setAttributes(attributes, ofItemAtPath: url.path)
            return
        }

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        guard let posixPermissions = attributes[.posixPermissions] as? NSNumber else {
            throw Entry.EntryError.missingPermissionsAttributeError
        }

        try self.setSymlinkPermissions(posixPermissions, ofItemAtURL: url)

        guard let modificationDate = attributes[.modificationDate] as? Date else {
            throw Entry.EntryError.missingModificationDateAttributeError
        }

        try self.setSymlinkModificationDate(modificationDate, ofItemAtURL: url)
#else
        // Since non-Darwin POSIX platforms ignore permissions on symlinks and swift-corelibs-foundation
        // currently doesn't support setting the modification date, this codepath is currently a no-op
        // on these platforms.
        return
#endif
    }

    func setSymlinkPermissions(_ posixPermissions: NSNumber, ofItemAtURL url: URL) throws {
        let fileSystemRepresentation = self.fileSystemRepresentation(withPath: url.path)
        let modeT = posixPermissions.uint16Value
        guard lchmod(fileSystemRepresentation, mode_t(modeT)) == 0 else {
            throw POSIXError(errno, path: url.path)
        }
    }

    func setSymlinkModificationDate(_ modificationDate: Date, ofItemAtURL url: URL) throws {
        let fileSystemRepresentation = self.fileSystemRepresentation(withPath: url.path)
        var fileStat = stat()
        guard lstat(fileSystemRepresentation, &fileStat) == 0 else {
            throw POSIXError(errno, path: url.path)
        }

        let accessDate = fileStat.lastAccessDate
        let array = [
            timeval(timeIntervalSince1970: accessDate.timeIntervalSince1970),
            timeval(timeIntervalSince1970: modificationDate.timeIntervalSince1970)
        ]
        try array.withUnsafeBufferPointer {
            guard lutimes(fileSystemRepresentation, $0.baseAddress) == 0 else {
                throw POSIXError(errno, path: url.path)
            }
        }
    }

    class func attributes(from entry: Entry) -> [FileAttributeKey: Any] {
        let centralDirectoryStructure = entry.centralDirectoryStructure
        let entryType = entry.type
        let fileTime = centralDirectoryStructure.lastModFileTime
        let fileDate = centralDirectoryStructure.lastModFileDate
        let defaultPermissions = entryType == .directory ? defaultDirectoryPermissions : defaultFilePermissions
        var attributes = [.posixPermissions: defaultPermissions] as [FileAttributeKey: Any]
        // Certain keys are not yet supported in swift-corelibs
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        attributes[.modificationDate] = Date(dateTime: (fileDate, fileTime))
#endif
        let versionMadeBy = centralDirectoryStructure.versionMadeBy
        guard let osType = Entry.OSType(rawValue: UInt(versionMadeBy >> 8)) else { return attributes }

        let externalFileAttributes = centralDirectoryStructure.externalFileAttributes
        let permissions = self.permissions(for: externalFileAttributes, osType: osType, entryType: entryType)
        attributes[.posixPermissions] = NSNumber(value: permissions)
        return attributes
    }

    class func permissions(for externalFileAttributes: UInt32, osType: Entry.OSType,
                           entryType: Entry.EntryType) -> UInt16 {
        switch osType {
        case .unix, .osx:
            let permissions = mode_t(externalFileAttributes >> 16) & (~S_IFMT)
            let defaultPermissions = entryType == .directory ? defaultDirectoryPermissions : defaultFilePermissions
            return permissions == 0 ? defaultPermissions : UInt16(permissions)
        default:
            return entryType == .directory ? defaultDirectoryPermissions : defaultFilePermissions
        }
    }

    class func externalFileAttributesForEntry(of type: Entry.EntryType, permissions: UInt16) -> UInt32 {
        var typeInt: UInt16
        switch type {
        case .file:
            typeInt = UInt16(S_IFREG)
        case .directory:
            typeInt = UInt16(S_IFDIR)
        case .symlink:
            typeInt = UInt16(S_IFLNK)
        }
        var externalFileAttributes = UInt32(typeInt|UInt16(permissions))
        externalFileAttributes = (externalFileAttributes << 16)
        return externalFileAttributes
    }

    class func permissionsForItem(at URL: URL) throws -> UInt16 {
        let fileManager = FileManager()
        let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: URL.path)
        var fileStat = stat()
        lstat(entryFileSystemRepresentation, &fileStat)
        let permissions = fileStat.st_mode
        return UInt16(permissions)
    }

    class func fileModificationDateTimeForItem(at url: URL) throws -> Date {
        let fileManager = FileManager()
        guard fileManager.itemExists(at: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: url.path)
        var fileStat = stat()
        lstat(entryFileSystemRepresentation, &fileStat)
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        let modTimeSpec = fileStat.st_mtimespec
#else
        let modTimeSpec = fileStat.st_mtim
#endif

        let timeStamp = TimeInterval(modTimeSpec.tv_sec) + TimeInterval(modTimeSpec.tv_nsec)/1000000000.0
        let modDate = Date(timeIntervalSince1970: timeStamp)
        return modDate
    }

    class func fileSizeForItem(at url: URL) throws -> Int64 {
        let fileManager = FileManager()
        guard fileManager.itemExists(at: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: url.path)
        var fileStat = stat()
        lstat(entryFileSystemRepresentation, &fileStat)
        guard fileStat.st_size >= 0 else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path])
        }
        // `st_size` is a signed int value
        return Int64(fileStat.st_size)
    }

    class func typeForItem(at url: URL) throws -> Entry.EntryType {
        let fileManager = FileManager()
        guard url.isFileURL, fileManager.itemExists(at: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: url.path)
        var fileStat = stat()
        lstat(entryFileSystemRepresentation, &fileStat)
        return Entry.EntryType(mode: mode_t(fileStat.st_mode))
    }
}

extension POSIXError {

    init(_ code: Int32, path: String) {
        let errorCode = POSIXError.Code(rawValue: code) ?? .EPERM
        self = .init(errorCode, userInfo: [NSFilePathErrorKey: path])
    }
}

extension CocoaError {

#if swift(>=4.2)
#else

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
#else

    // The swift-corelibs-foundation version of NSError.swift was missing a convenience method to create
    // error objects from error codes. (https://github.com/apple/swift-corelibs-foundation/pull/1420)
    // We have to provide an implementation for non-Darwin platforms using Swift versions < 4.2.

    public static func error(_ code: CocoaError.Code, userInfo: [AnyHashable: Any]? = nil, url: URL? = nil) -> Error {
        var info: [String: Any] = userInfo as? [String: Any] ?? [:]
        if let url = url {
            info[NSURLErrorKey] = url
        }
        return NSError(domain: NSCocoaErrorDomain, code: code.rawValue, userInfo: info)
    }

#endif
#endif
}

public extension URL {
    func isContained(in parentDirectoryURL: URL) -> Bool {
        // Ensure this URL is contained in the passed in URL
        let parentDirectoryURL = URL(fileURLWithPath: parentDirectoryURL.path, isDirectory: true).standardized
        return self.standardized.absoluteString.hasPrefix(parentDirectoryURL.absoluteString)
    }
}
