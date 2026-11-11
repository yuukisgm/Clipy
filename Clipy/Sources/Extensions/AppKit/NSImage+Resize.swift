//
//  NSImage+Resize.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2015/07/26.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation
import Cocoa

extension NSImage {
    /// 最長辺が `maxLongerSide` を超える場合のみアスペクト比を保って縮小して返す。
    /// 4K/Retina スクショなどの過剰解像度を取り込み時に正規化し、tiffRepresentation の
    /// 中間ビットマップ (width × height × 4 byte) を抑える目的。
    func downscaledIfNeeded(maxLongerSide: CGFloat) -> NSImage {
        let longer = max(size.width, size.height)
        guard longer > maxLongerSide, longer > 0 else { return self }
        let scale = maxLongerSide / longer
        let newSize = NSSize(width: floor(size.width * scale),
                             height: floor(size.height * scale))
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    func resizedToFit(maxSize: NSSize) -> NSImage {
        guard size.width > 0, size.height > 0, maxSize.width > 0, maxSize.height > 0 else { return self }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1.0)
        guard scale < 1.0 else { return self }
        let newSize = NSSize(width: floor(size.width * scale),
                             height: floor(size.height * scale))
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
