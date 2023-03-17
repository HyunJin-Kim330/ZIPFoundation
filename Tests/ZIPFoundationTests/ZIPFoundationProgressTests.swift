//
//  ZIPFoundationProgressTests.swift
//  ZIPFoundation
//
//  Copyright © 2017-2023 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//
import XCTest
@testable import ZIPFoundation

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
extension ZIPFoundationTests {

    func testArchiveAddUncompressedEntryProgress() {
        let archive = self.archive(for: #function, mode: .update)
        let assetURL = self.resourceURL(for: #function, pathExtension: "png")
        let progress = archive.makeProgressForAddingItem(at: assetURL)
        let handler: XCTKVOExpectation.Handler = { (_, _) -> Bool in
            if progress.fractionCompleted > 0.5 {
                progress.cancel()
                return true
            }
            return false
        }
        let cancel = self.keyValueObservingExpectation(for: progress, keyPath: #keyPath(Progress.fractionCompleted),
                                                       handler: handler)
        let zipQueue = DispatchQueue(label: "ZIPFoundationTests")
        zipQueue.async {
            do {
                let relativePath = assetURL.lastPathComponent
                let baseURL = assetURL.deletingLastPathComponent()
                try archive.addEntry(with: relativePath, relativeTo: baseURL, bufferSize: 1, progress: progress)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            } catch {
                XCTFail("Failed to add entry to uncompressed folder archive with error : \(error)")
            }
        }
        self.wait(for: [cancel], timeout: 20.0)
        zipQueue.sync {
            XCTAssert(progress.fractionCompleted > 0.5)
            XCTAssert(archive.checkIntegrity())
        }
    }

    func testArchiveAddCompressedEntryProgress() {
        let archive = self.archive(for: #function, mode: .update)
        let assetURL = self.resourceURL(for: #function, pathExtension: "png")
        let progress = archive.makeProgressForAddingItem(at: assetURL)
        let handler: XCTKVOExpectation.Handler = { (_, _) -> Bool in
            if progress.fractionCompleted > 0.5 {
                progress.cancel()
                return true
            }
            return false
        }
        let cancel = self.keyValueObservingExpectation(for: progress, keyPath: #keyPath(Progress.fractionCompleted),
                                                       handler: handler)
        let zipQueue = DispatchQueue(label: "ZIPFoundationTests")
        zipQueue.async {
            do {
                let relativePath = assetURL.lastPathComponent
                let baseURL = assetURL.deletingLastPathComponent()
                try archive.addEntry(with: relativePath, relativeTo: baseURL,
                                     compressionMethod: .deflate, bufferSize: 1, progress: progress)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            } catch {
                XCTFail("Failed to add entry to uncompressed folder archive with error : \(error)")
            }
        }
        self.wait(for: [cancel], timeout: 20.0)
        zipQueue.sync {
            XCTAssert(progress.fractionCompleted > 0.5)
            XCTAssert(archive.checkIntegrity())
        }
    }

    func testRemoveEntryProgress() {
        let archive = self.archive(for: #function, mode: .update)
        guard let entryToRemove = archive["test/data.random"] else {
            XCTFail("Failed to find entry to remove in uncompressed folder")
            return
        }
        let progress = archive.makeProgressForRemoving(entryToRemove)
        let handler: XCTKVOExpectation.Handler = { (_, _) -> Bool in
            if progress.fractionCompleted > 0.5 {
                progress.cancel()
                return true
            }
            return false
        }
        let cancel = self.keyValueObservingExpectation(for: progress, keyPath: #keyPath(Progress.fractionCompleted),
                                                       handler: handler)
        let zipQueue = DispatchQueue(label: "ZIPFoundationTests")
        zipQueue.async {
            do {
                try archive.remove(entryToRemove, progress: progress)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            } catch {
                XCTFail("Failed to remove entry from uncompressed folder archive with error : \(error)")
            }
        }
        self.wait(for: [cancel], timeout: 20.0)
        zipQueue.sync {
            XCTAssert(progress.fractionCompleted > 0.5)
            XCTAssert(archive.checkIntegrity())
        }
    }

    func testZipItemProgress() {
        let fileManager = FileManager()
        let assetURL = self.resourceURL(for: #function, pathExtension: "png")
        var fileArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        fileArchiveURL.appendPathComponent(self.archiveName(for: #function))
        let fileProgress = Progress()
        let fileExpectation = self.keyValueObservingExpectation(for: fileProgress,
                                                                keyPath: #keyPath(Progress.fractionCompleted),
                                                                expectedValue: 1.0)
        var didSucceed = true
        let testQueue = DispatchQueue.global()
        testQueue.async {
            do {
                let result = try fileManager.zipItem(at: assetURL, to: fileArchiveURL, progress: fileProgress, completionHandler: {print()})
            } catch { didSucceed = false }
        }
        var directoryURL = ZIPFoundationTests.tempZipDirectoryURL
        directoryURL.appendPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        var directoryArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        directoryArchiveURL.appendPathComponent(self.archiveName(for: #function, suffix: "Directory"))
        let newAssetURL = directoryURL.appendingPathComponent(assetURL.lastPathComponent)
        let directoryProgress = Progress()
        let directoryExpectation = self.keyValueObservingExpectation(for: directoryProgress,
                                                                     keyPath: #keyPath(Progress.fractionCompleted),
                                                                     expectedValue: 1.0)
        testQueue.async {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
                try fileManager.createDirectory(at: directoryURL.appendingPathComponent("nested"),
                                                withIntermediateDirectories: true, attributes: nil)
                try fileManager.copyItem(at: assetURL, to: newAssetURL)
                try fileManager.createSymbolicLink(at: directoryURL.appendingPathComponent("link"),
                                                   withDestinationURL: newAssetURL)
                let result = try fileManager.zipItem(at: directoryURL, to: directoryArchiveURL, progress: directoryProgress, completionHandler: {print()})
            } catch { didSucceed = false }
        }
        self.wait(for: [fileExpectation, directoryExpectation], timeout: 20.0)
        guard let archive = Archive(url: fileArchiveURL, accessMode: .read),
              let directoryArchive = Archive(url: directoryArchiveURL, accessMode: .read) else {
            XCTFail("Failed to read archive.") ; return
        }
        XCTAssert(didSucceed)
        XCTAssert(archive.checkIntegrity())
        XCTAssert(directoryArchive.checkIntegrity())
    }
    
    func testZipItems() {
        let fileManager = FileManager()
        let zipFiles: [URL] = [URL(fileURLWithPath: "/Volumes/보안드라이브/sf.pptx"), URL(fileURLWithPath: "/Volumes/보안드라이브/sf 2.pptx")]
        let zipLocation: URL = URL(fileURLWithPath: "/Volumes/보안드라이브/아카이브e.zip")
        
        do {
            _ = try fileManager.zipItem(at: zipFiles[0], to: zipLocation, completionHandler: {print()})
        } catch {
            let err = error as NSError
            print(err.code)
            
//            if let posixError = err.userInfo["NSUnderlyingError"] as? NSError {
//                print(posixError.code)
//            }
        }
        
        if zipFiles.count >= 2 {
            guard let archive = Archive(url: zipLocation, accessMode: .update) else {
                return
            }

            for i in 1 ..< zipFiles.count {
                do {
                    try archive.addEntry(with: zipFiles[i].lastPathComponent, relativeTo: zipFiles[i].deletingLastPathComponent())
                } catch {
                    let err = error as NSError
                    print(err.code)
                }
            }
        }
    }

    func testUnzipItemProgress() {
        let fileManager = FileManager()
//        let sourceURL = URL(fileURLWithPath: "/Users/khj-mac/Desktop/무제 폴더 2/아카이브 2.zip")
//        let destinationURL = URL(fileURLWithPath: "/Users/khj-mac/Desktop/무제 폴더 2/")
        let sourceURL = URL(fileURLWithPath: "/Volumes/보안드라이브/무제 폴더.zip")
        let destinationURL = URL(fileURLWithPath: "/Volumes/보안드라이브")
        
        
        do {
            let result = try fileManager.unzipItem(at: sourceURL, to: destinationURL, progress: Progress(), preferredEncoding: .utf8, completionHandler: {print("끝남 ㅎㅎ")})
            result()
        } catch {
            let err = error as NSError
            print(err.code)
        }
    }

    func testZIP64ArchiveAddEntryProgress() {
        self.mockIntMaxValues()
        defer { self.resetIntMaxValues() }
        let archive = self.archive(for: #function, mode: .update)
        let assetURL = self.resourceURL(for: #function, pathExtension: "png")
        let progress = archive.makeProgressForAddingItem(at: assetURL)
        let handler: XCTKVOExpectation.Handler = { (_, _) -> Bool in
            if progress.fractionCompleted > 0.5 {
                progress.cancel()
                return true
            }
            return false
        }
        let cancel = self.keyValueObservingExpectation(for: progress, keyPath: #keyPath(Progress.fractionCompleted),
                                                       handler: handler)
        let zipQueue = DispatchQueue(label: "ZIPFoundationTests")
        zipQueue.async {
            do {
                let relativePath = assetURL.lastPathComponent
                let baseURL = assetURL.deletingLastPathComponent()
                try archive.addEntry(with: relativePath, relativeTo: baseURL,
                                     compressionMethod: .deflate, bufferSize: 1, progress: progress)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            } catch {
                XCTFail("Failed to add entry to uncompressed folder archive with error : \(error)")
            }
        }
        self.wait(for: [cancel], timeout: 20.0)
        zipQueue.sync {
            XCTAssert(progress.fractionCompleted > 0.5)
            XCTAssert(archive.checkIntegrity())
        }
    }
}
#endif
