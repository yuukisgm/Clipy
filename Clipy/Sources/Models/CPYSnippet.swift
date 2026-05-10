//
//  CPYSnippet.swift
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

final class CPYSnippet: NSObject {

    // MARK: - Properties
    var index = 0
    var enable = true
    var title = ""
    var content = ""
    var identifier = UUID().uuidString
    weak var folder: CPYFolder?

    var isInvalidated: Bool {
        return false
    }
}

extension CPYSnippet {
    convenience init(index: Int, enable: Bool, title: String, content: String, identifier: String) {
        self.init()
        self.index = index
        self.enable = enable
        self.title = title
        self.content = content
        self.identifier = identifier
    }
}

extension CPYSnippet: Codable {

    enum CodingKeys: String, CodingKey {
        case index
        case enable
        case title
        case content
        case identifier
    }

    convenience init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        enable = try container.decode(Bool.self, forKey: .enable)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        identifier = try container.decode(String.self, forKey: .identifier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(enable, forKey: .enable)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(identifier, forKey: .identifier)
    }
}

// MARK: - Add Snippet
extension CPYSnippet {
    func merge() {
        SQLiteClipStore.shared.upsertSnippet(self, folderIdentifier: folder?.identifier)
    }
}

// MARK: - Remove Snippet
extension CPYSnippet {
    func remove() {
        SQLiteClipStore.shared.deleteSnippet(identifier: identifier)
    }
}
