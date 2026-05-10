//
//  CPYClip.swift
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

final class CPYClip: NSObject {

    // MARK: - Properties
    var dataPath = ""
    var title = ""
    var dataHash = ""
    var primaryType = ""
    var updateTime = 0
    var thumbnailPath = ""
    var isColorCode = false

    var isInvalidated: Bool {
        return false
    }

    convenience init(dataPath: String,
                     title: String,
                     dataHash: String,
                     primaryType: String,
                     updateTime: Int,
                     thumbnailPath: String,
                     isColorCode: Bool) {
        self.init()
        self.dataPath = dataPath
        self.title = title
        self.dataHash = dataHash
        self.primaryType = primaryType
        self.updateTime = updateTime
        self.thumbnailPath = thumbnailPath
        self.isColorCode = isColorCode
    }
}

extension CPYClip {
    func previewTitle(maxLength: Int) -> String {
        guard maxLength > 0, title.count > maxLength else { return title }
        return String(title.prefix(maxLength))
    }
}
