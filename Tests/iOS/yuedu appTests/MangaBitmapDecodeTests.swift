import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 独立合成横条乱序图，验证书源实际使用的Android Bitmap/Canvas裁剪拼接合同。
@Suite("漫画横条图片还原", .serialized)
struct MangaBitmapDecodeTests {
    @Test("源脚本按Rect裁剪横条后还原原尺寸，而不是显示乱序下载图", arguments: [80, 85])
    func reconstructsStrips(height: Int) async throws {
        let raw = try Self.image(width: 16, height: height, scrambled: true)
        let expected = try Self.image(width: 16, height: height, scrambled: false)
        var source = BookSource(bookSourceUrl: "https://bitmap-fixture.invalid/\(UUID().uuidString)", bookSourceName: "合成图片解码")
        source.ruleContent.imageDecode = Self.rule
        let decoder = try #require(FixedPageImageDecoder(source: source))
        let output = try #require(await decoder.decode(raw, src: "https://bitmap-fixture.invalid/media/photos/250000/1.png"))
        let bitmap = try #require(UIImage(data: output)?.cgImage)
        #expect(bitmap.width == 16)
        #expect(bitmap.height == height)
        #expect(try Self.pixels(output) == Self.pixels(expected), "还原后的像素必须按原顺序排列；返回下载原图不能算解码成功")
    }

    @Test("decodeByteArray只读取指定字节区间，PNG压缩不改变像素")
    func byteRangeAndLosslessPNG() throws {
        let png = try Self.image(width: 16, height: 85, scrambled: false)
        let bytes = Data([1, 2, 3]) + png + Data([4, 5])
        let engine = JSCoreEngine()
        let decoded = try #require(engine.evaluateBytes("""
        (function () {
            var bitmap = Packages.android.graphics.BitmapFactory.decodeByteArray(result, 3, result.length - 5);
            var stream = new Packages.java.io.ByteArrayOutputStream();
            bitmap.compress(Packages.android.graphics.Bitmap.CompressFormat.PNG, 100, stream);
            bitmap.recycle();
            return stream.toByteArray();
        })()
        """, data: bytes))
        #expect(try Self.pixels(decoded) == Self.pixels(png))
    }

    @Test("Canvas只复制源Rect，裁剪不能缩放整张图到目标横条")
    func copiesOnlySourceRect() throws {
        let png = try Self.image(width: 16, height: 85, scrambled: false)
        let engine = JSCoreEngine()
        let output = try #require(engine.evaluateBytes("""
        (function () {
            var image = Packages.android.graphics.BitmapFactory.decodeByteArray(result, 0, result.length);
            var target = Packages.android.graphics.Bitmap.createBitmap(16, 17, Packages.android.graphics.Bitmap.Config.ARGB_8888);
            var canvas = new Packages.android.graphics.Canvas(target);
            canvas.drawBitmap(image, new Packages.android.graphics.Rect(0, 20, 16, 37),
                new Packages.android.graphics.Rect(0, 0, 16, 17), null);
            var stream = new Packages.java.io.ByteArrayOutputStream();
            target.compress(Packages.android.graphics.Bitmap.CompressFormat.PNG, 100, stream);
            return stream.toByteArray();
        })()
        """, data: png))
        let expected = try Self.pixels(png).subdata(in: (20 * 16 * 4)..<(37 * 16 * 4))
        #expect(try Self.pixels(output) == expected)
    }

    @Test("无效图片返回null，越界与超大像素预算明确抛错")
    func rejectsInvalidInputAndDimensions() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("Packages.android.graphics.BitmapFactory.decodeByteArray([1,2,3],0,3) === null") == "true")
        #expect(engine.evaluate("""
        (function () {
            var rejected = 0;
            try { Packages.android.graphics.BitmapFactory.decodeByteArray([1,2],0,3); } catch (_) { rejected++; }
            try { Packages.android.graphics.Bitmap.createBitmap(8192,8192,Packages.android.graphics.Bitmap.Config.ARGB_8888); } catch (_) { rejected++; }
            try { Packages.android.graphics.Bitmap.createBitmap(10,10,'RGB_565'); } catch (_) { rejected++; }
            return rejected;
        })()
        """) == "3")
    }

    @Test("多张乱序图片走下载解码与翻页链路后仍是独立漫画页")
    @MainActor
    func decodedImagesRemainSeparatePages() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("MangaBitmapPages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let raw = try Self.image(width: 16, height: 20, scrambled: true)
        let expected = try Self.pixels(Self.image(width: 16, height: 20, scrambled: false))
        var source = BookSource(bookSourceUrl: "https://bitmap-pages-fixture.invalid/\(UUID().uuidString)", bookSourceName: "合成多图")
        source.ruleContent.imageDecode = Self.rule
        let decoder = try #require(FixedPageImageDecoder(source: source))
        let content = (0..<3).map { "<img src=\"https://bitmap-pages-fixture.invalid/\($0).png\">" }.joined()
        var pages = MangaChapterParser.pages(from: content, headers: [:], imageDecoder: decoder)
        #expect(pages.map(\.id) == [0, 1, 2])
        for index in pages.indices {
            let local = directory.appendingPathComponent("\(index).png")
            try raw.write(to: local)
            pages[index].localURL = local
        }
        let width = FixedPageTargetWidth()
        width.value = 400
        let paged = FixedPagePagedViewController(fixedPageReaderConfiguration: .recommendedDefault(for: .ltr), targetWidth: width)
        paged.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        paged.setPages(pages, startPage: 0)
        for index in pages.indices {
            paged.goToPage(index, animated: false)
            paged.view.layoutIfNeeded()
            let pageView = try #require(paged.children.first as? UIPageViewController)
            let spread = try #require(pageView.viewControllers?.first as? FixedPageSpreadViewController)
            spread.view.layoutIfNeeded()
            #expect(spread.pageControllers.count == 1)
            let page = try #require(spread.pageControllers.first)
            await page.loadTask?.value
            spread.view.layoutIfNeeded()
            let image = try #require(page.imageView.image)
            #expect(try Self.pixels(#require(image.pngData())) == expected)
            #expect(paged.currentPageIndex() == index)
            #expect(abs(page.imageView.frame.width - 400) < 0.5)
        }
    }

    @Test("同一源连续解码图片不因等待JS垃圾回收耗尽位图预算")
    func consecutivePagesReleaseNativeBitmaps() async throws {
        let raw = try Self.image(width: 512, height: 1024, scrambled: true)
        var source = BookSource(bookSourceUrl: "https://bitmap-budget-fixture.invalid/\(UUID().uuidString)", bookSourceName: "合成连续图片")
        source.ruleContent.imageDecode = Self.rule
        let decoder = try #require(FixedPageImageDecoder(source: source))
        for page in 0..<40 {
            let output = try #require(await decoder.decode(raw, src: "https://bitmap-budget-fixture.invalid/\(page).png"))
            #expect(output != raw, "第\(page)页不能因Native位图未释放而退回乱序原图")
        }
    }

    @Test("多个JSContext共享总位图预算，回收后可再次分配")
    func contextsSharePixelBudget() {
        let first = JSCoreEngine(), second = JSCoreEngine()
        let firstCount = Int(first.evaluate("""
        var held = [];
        for (var i = 0; i < 256; i++) {
            try { held.push(Packages.android.graphics.Bitmap.createBitmap(256,256,Packages.android.graphics.Bitmap.Config.ARGB_8888)); }
            catch (_) { break; }
        }
        held.length;
        """) ?? "") ?? 0
        #expect(firstCount > 0)
        let secondResult = second.evaluate("""
        var held = [], limited = false;
        for (var i = 0; i < 513; i++) {
            try { held.push(Packages.android.graphics.Bitmap.createBitmap(256,256,Packages.android.graphics.Bitmap.Config.ARGB_8888)); }
            catch (_) { limited = true; break; }
        }
        held.length + '|' + limited;
        """)?.split(separator: "|") ?? []
        #expect(secondResult.last == "true")
        let secondCount = Int(secondResult.first ?? "") ?? 0
        #expect(firstCount + secondCount <= 512)
        #expect(first.evaluate("held.forEach(function(b){b.recycle();}); 'released';") == "released")
        #expect(second.evaluate("Packages.android.graphics.Bitmap.createBitmap(16,16,Packages.android.graphics.Bitmap.Config.ARGB_8888).getWidth()") == "16")
        #expect(second.evaluate("held.forEach(function(b){b.recycle();}); 'released';") == "released")
    }

    @Test("回收位图会释放资源，不能继续压缩已回收图片")
    func recycledBitmapIsNotUsable() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("""
        (function () {
            var bitmap = Packages.android.graphics.Bitmap.createBitmap(16,16,Packages.android.graphics.Bitmap.Config.ARGB_8888);
            bitmap.recycle();
            var rejected = false;
            try { bitmap.compress(Packages.android.graphics.Bitmap.CompressFormat.PNG,100,new Packages.java.io.ByteArrayOutputStream()); }
            catch (_) { rejected = true; }
            return bitmap.isRecycled() && rejected;
        })()
        """) == "true")
    }

    static let rule = """
    (function () {
        try {
            var bitmap = Packages.android.graphics.BitmapFactory.decodeByteArray(result, 0, result.length);
            var w = bitmap.getWidth(), h = bitmap.getHeight(), strips = 10;
            var output = Packages.android.graphics.Bitmap.createBitmap(w, h, Packages.android.graphics.Bitmap.Config.ARGB_8888);
            var canvas = new Packages.android.graphics.Canvas(output);
            var paint = new Packages.android.graphics.Paint();
            var step = Math.floor(h / strips), remainder = h % strips;
            for (var i = 0; i < strips; i++) {
                var height = step + (i === 0 ? remainder : 0);
                var from = h - step * (i + 1) - remainder;
                var to = step * i + (i === 0 ? 0 : remainder);
                canvas.drawBitmap(bitmap,
                    new Packages.android.graphics.Rect(0, from, w, from + height),
                    new Packages.android.graphics.Rect(0, to, w, to + height), paint);
            }
            var bytes = new Packages.java.io.ByteArrayOutputStream();
            output.compress(Packages.android.graphics.Bitmap.CompressFormat.PNG, 100, bytes);
            return bytes.toByteArray();
        } catch (error) {
            // 模拟源内捕获异常后返回原图的既有行为；像素断言仍必须发现失败。
            return result;
        }
    })()
    """

    static func image(width: Int, height: Int, scrambled: Bool) throws -> Data {
        var rows = (0..<height).map { row -> [UInt8] in
            (0..<width).flatMap { column in [UInt8((row % 128) * 2), UInt8((column % 32) * 8), UInt8(255 - (row % 128) * 2), 255] }
        }
        if scrambled {
            let original = rows
            let step = height / 10, remainder = height % 10
            for i in 0..<10 {
                let length = step + (i == 0 ? remainder : 0)
                let destination = height - step * (i + 1) - remainder
                let start = step * i + (i == 0 ? 0 : remainder)
                rows.replaceSubrange(destination..<(destination + length), with: original[start..<(start + length)])
            }
        }
        let pixels = Data(rows.flatMap { $0 })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let bitmap = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try #require(UIImage(cgImage: bitmap).pngData())
    }

    static func pixels(_ data: Data) throws -> Data {
        let image = try #require(UIImage(data: data)?.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes)
    }
}
