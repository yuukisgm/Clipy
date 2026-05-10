//
//  CPYFolder.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2015/06/21.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Cocoa

final class CPYFolder: NSObject, Codable {

    // MARK: - Properties
    var index = 0
    var enable = true
    var title = ""
    var identifier = UUID().uuidString
    var snippets = [CPYSnippet]() {
        didSet { snippets.forEach { $0.folder = self } }
    }

    var isInvalidated: Bool {
        return false
    }

}

extension CPYFolder {
    convenience init(index: Int, enable: Bool, title: String, identifier: String, snippets: [CPYSnippet]) {
        self.init()
        self.index = index
        self.enable = enable
        self.title = title
        self.identifier = identifier
        self.snippets = snippets
        self.snippets.forEach { $0.folder = self }
    }
}

// MARK: - Copy
extension CPYFolder {
    func deepCopy() -> CPYFolder {
        let folder = CPYFolder()
        folder.index = index
        folder.enable = enable
        folder.title = title
        folder.identifier = identifier
        folder.snippets = snippets.sorted { $0.index < $1.index }.map {
            CPYSnippet(index: $0.index,
                       enable: $0.enable,
                       title: $0.title,
                       content: $0.content,
                       identifier: $0.identifier)
        }
        return folder
    }
}

// MARK: - Add Snippet
extension CPYFolder {
    func createSnippet() -> CPYSnippet {
        let snippet = CPYSnippet()
        snippet.title = "untitled snippet"
        snippet.index = Int(snippets.count)
        snippet.folder = self
        return snippet
    }

    func mergeSnippet(_ snippet: CPYSnippet) {
        snippet.folder = self
        SQLiteClipStore.shared.upsertSnippet(snippet, folderIdentifier: identifier)
    }

    func insertSnippet(_ snippet: CPYSnippet, index: Int) {
        snippet.folder = self
        SQLiteClipStore.shared.moveSnippet(snippet.identifier, toFolderIdentifier: identifier, index: index)
        rearrangesSnippetIndex()
    }

    func removeSnippet(_ snippet: CPYSnippet) {
        SQLiteClipStore.shared.removeSnippet(snippet.identifier, fromFolderIdentifier: identifier)
        rearrangesSnippetIndex()
    }
}

// MARK: - Add Folder
extension CPYFolder {
    static func create() -> CPYFolder {
        let folder = CPYFolder()
        folder.title = "untitled folder"
        folder.index = SQLiteClipStore.shared.lastFolderIndex() ?? -1
        folder.index += 1
        return folder
    }

    func merge() {
        SQLiteClipStore.shared.upsertFolder(self)
    }
}

// MARK: - Remove Folder
extension CPYFolder {
    func remove() {
        SQLiteClipStore.shared.deleteFolder(identifier: identifier)
    }
}

// MARK: - Migrate Index
extension CPYFolder {
    static func rearrangesIndex(_ folders: [CPYFolder]) {
        for (index, folder) in folders.enumerated() {
            folder.index = index
            SQLiteClipStore.shared.updateFolderIndex(identifier: folder.identifier, index: index)
        }
    }

    func rearrangesSnippetIndex() {
        for (index, snippet) in snippets.enumerated() {
            snippet.index = index
            SQLiteClipStore.shared.updateSnippetIndex(identifier: snippet.identifier, index: index)
        }
    }
}
