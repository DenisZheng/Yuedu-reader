import CoreGraphics
import Foundation
import ImageIO
import JavaScriptCore
import os
import UniformTypeIdentifiers

/// 仅在既有JS执行队列上处理图片；不向源脚本提供文件、网络或系统访问。
@objc private protocol LegadoGraphicsExport: JSExport {
    func decode(_ bytes: JSValue, _ offset: Double, _ length: Double) -> LegadoGraphicsBitmap?
    func create(_ width: Double, _ height: Double) -> LegadoGraphicsBitmap?
    func draw(_ target: LegadoGraphicsBitmap, _ source: LegadoGraphicsBitmap,
              _ from: [String: Double], _ to: [String: Double], _ filtered: Bool) -> Bool
    func encode(_ bitmap: LegadoGraphicsBitmap, _ format: String, _ quality: Double) -> JSValue?
}

@objc protocol LegadoGraphicsBitmapExport: JSExport {
    func getWidth() -> Int
    func getHeight() -> Int
    func recycle()
    func isRecycled() -> Bool
}

/// Bitmap持有期间计费，回收或GC时释放；同时限制单个Context与所有Context合计，不建立图片缓存。
private final class LegadoGraphicsBudget: @unchecked Sendable {
    static let maximumPixels = 16 * 1024 * 1024
    private static let total = OSAllocatedUnfairLock(initialState: 0)
    private let lock = NSLock()
    private var used = 0
    func acquire(_ pixels: Int) -> Bool {
        lock.withLock {
            guard pixels > 0, pixels <= Self.maximumPixels,
                  used <= 2 * Self.maximumPixels - pixels else { return false }
            return Self.total.withLock { total in
                guard total <= 2 * Self.maximumPixels - pixels else { return false }
                used += pixels
                total += pixels
                return true
            }
        }
    }
    func release(_ pixels: Int) {
        lock.withLock {
            used -= pixels
            Self.total.withLock { $0 -= pixels }
        }
    }
}

final class LegadoGraphicsBitmap: NSObject, LegadoGraphicsBitmapExport {
    fileprivate var image: CGImage?
    fileprivate var canvas: CGContext?
    private var pixels: Int
    private let budget: LegadoGraphicsBudget
    private let width: Int
    private let height: Int

    fileprivate init(image: CGImage?, canvas: CGContext?, width: Int, height: Int, budget: LegadoGraphicsBudget) {
        self.image = image; self.canvas = canvas; self.width = width; self.height = height
        self.budget = budget; self.pixels = width * height
        super.init()
    }
    deinit { budget.release(pixels) }
    func getWidth() -> Int { width }
    func getHeight() -> Int { height }
    func isRecycled() -> Bool { pixels == 0 }
    func recycle() {
        image = nil; canvas = nil
        budget.release(pixels)
        pixels = 0
    }
    fileprivate var snapshot: CGImage? { canvas?.makeImage() ?? image }
}

final class LegadoGraphicsBridge: NSObject, LegadoGraphicsExport {
    private let budget = LegadoGraphicsBudget()
    private static let maximumBytes = 8 * 1024 * 1024

    /// Android decodeByteArray读取指定字节区间；无效图片返回null，越界和预算失败抛出异常。
    func decode(_ bytes: JSValue, _ offset: Double, _ length: Double) -> LegadoGraphicsBitmap? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let offset = integer(offset), let length = integer(length),
              let count = integer(bytes.objectForKeyedSubscript("length")?.toDouble() ?? -1),
              count <= Self.maximumBytes, length <= Self.maximumBytes, offset <= count, length <= count - offset else {
            return failure("BitmapFactory byte range exceeds limit")
        }
        guard let values = bytes.toArray() as? [NSNumber], values.count == count else {
            return failure("BitmapFactory requires a byte array")
        }
        let data = Data(values[offset..<(offset + length)].map { UInt8(truncating: $0) })
        return SourcePerfTrace.span("source.bitmap.decode", "main=\(Thread.isMainThread) bytes=\(length)") {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            guard let pixels = pixelCount(width: width, height: height), budget.acquire(pixels) else {
                return failure("BitmapFactory pixel budget exceeded")
            }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                budget.release(pixels)
                return nil
            }
            return LegadoGraphicsBitmap(image: image, canvas: nil, width: width, height: height, budget: budget)
        }
    }

    func create(_ width: Double, _ height: Double) -> LegadoGraphicsBitmap? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let width = integer(width), let height = integer(height),
              let pixels = pixelCount(width: width, height: height), budget.acquire(pixels) else {
            return failure("Bitmap dimensions or pixel budget exceeded")
        }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            budget.release(pixels)
            return failure("Bitmap allocation failed")
        }
        return LegadoGraphicsBitmap(image: nil, canvas: context, width: width, height: height, budget: budget)
    }

    /// 源Rect是图片像素，目标Rect是Canvas像素；只绘制裁剪区域，绝不将整张图重复缩进横条。
    func draw(_ target: LegadoGraphicsBitmap, _ source: LegadoGraphicsBitmap,
              _ from: [String: Double], _ to: [String: Double], _ filtered: Bool) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !target.isRecycled(), !source.isRecycled(), let context = target.canvas,
              let image = source.snapshot, let src = rect(from), let dst = rect(to),
              CGRect(x: 0, y: 0, width: source.getWidth(), height: source.getHeight()).contains(src),
              let cropped = image.cropping(to: src) else {
            _ = failure("Canvas requires live bitmap and valid source/destination Rect") as JSValue?
            return false
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = filtered ? .default : .none
        // Android坐标原点在左上，CoreGraphics绘制坐标在左下；转换目标位置且保留图像方向。
        context.draw(cropped, in: CGRect(x: dst.minX, y: CGFloat(target.getHeight()) - dst.maxY,
                                        width: dst.width, height: dst.height))
        return true
    }

    func encode(_ bitmap: LegadoGraphicsBitmap, _ format: String, _ quality: Double) -> JSValue? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !bitmap.isRecycled(), let image = bitmap.snapshot, quality.isFinite, (0...100).contains(quality),
              ["PNG", "JPEG"].contains(format) else { return failure("Bitmap compression parameters invalid") }
        return SourcePerfTrace.span("source.bitmap.encode", "main=\(Thread.isMainThread) pixels=\(image.width * image.height)") {
            let data = NSMutableData()
            let type = format == "PNG" ? UTType.png.identifier : UTType.jpeg.identifier
            guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
                return failure("Bitmap compression destination unavailable")
            }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality / 100] as CFDictionary)
            guard CGImageDestinationFinalize(destination), data.length <= Self.maximumBytes else {
                return failure("Bitmap compressed output exceeds limit")
            }
            return JSValue(object: (data as Data).map(Int.init), in: JSContext.current())
        }
    }

    private func integer(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0, value <= Double(Int32.max), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
    private func pixelCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              width <= LegadoGraphicsBudget.maximumPixels / height else { return nil }
        return width * height
    }
    private func rect(_ values: [String: Double]) -> CGRect? {
        guard let left = values["left"], let top = values["top"], let right = values["right"], let bottom = values["bottom"],
              [left, top, right, bottom].allSatisfy({ $0.isFinite && abs($0) <= 32_768 }),
              right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    private func failure<T>(_ message: String) -> T? {
        if let context = JSContext.current() { context.exception = JSValue(newErrorFromMessage: message, in: context) }
        return nil
    }
}
