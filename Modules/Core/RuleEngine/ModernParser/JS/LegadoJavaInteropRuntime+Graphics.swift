import Foundation

extension LegadoJavaInteropRuntime {
    /// 共用原有Packages能力白名单和byte[]语义，仅支持图片解码实际用到的矩形绘制。
    static let graphicsScript = #"""
        var graphics = global.__yueduGraphics;
        delete global.__yueduGraphics;
        function Bitmap(handle) {
            if (!handle) throw new Error('Bitmap requires a native image');
            Object.defineProperty(this, '_handle', { value: handle });
        }
        Bitmap.prototype.getWidth = function () { return this._handle.getWidth(); };
        Bitmap.prototype.getHeight = function () { return this._handle.getHeight(); };
        Bitmap.prototype.recycle = function () { this._handle.recycle(); };
        Bitmap.prototype.isRecycled = function () { return this._handle.isRecycled(); };
        Bitmap.prototype.compress = function (format, quality, stream) {
            if (!stream || typeof stream.write !== 'function') throw new Error('Bitmap.compress requires an output stream');
            var bytes = graphics.encode(this._handle, String(format), Number(quality));
            if (bytes == null) return false;
            bytes = javaBytes(bytes);
            stream.write(bytes, 0, bytes.length);
            return true;
        };
        Bitmap.Config = Object.freeze({ ARGB_8888: 'ARGB_8888' });
        Bitmap.CompressFormat = Object.freeze({ PNG: 'PNG', JPEG: 'JPEG' });
        Bitmap.createBitmap = function (width, height, config) {
            if (config !== Bitmap.Config.ARGB_8888) throw new Error('Unsupported Bitmap.Config');
            var handle = graphics.create(Number(width), Number(height));
            return handle == null ? null : new Bitmap(handle);
        };
        var BitmapFactory = {
            decodeByteArray: function (bytes, offset, length) {
                var handle = graphics.decode(bytes && bytes.__bytes ? bytes.__bytes : bytes, Number(offset), Number(length));
                return handle == null ? null : new Bitmap(handle);
            }
        };
        function Rect(left, top, right, bottom) {
            this.left = Number(left); this.top = Number(top); this.right = Number(right); this.bottom = Number(bottom);
        }
        function Paint() { this._filtered = false; }
        Paint.prototype.setFilterBitmap = function (value) { this._filtered = !!value; };
        Paint.prototype.isFilterBitmap = function () { return this._filtered; };
        function Canvas(bitmap) {
            if (!(bitmap instanceof Bitmap)) throw new Error('Canvas requires a Bitmap');
            this._bitmap = bitmap;
        }
        Canvas.prototype.drawBitmap = function (bitmap, source, destination, paint) {
            if (!(bitmap instanceof Bitmap) || !(source instanceof Rect) || !(destination instanceof Rect)) {
                throw new Error('Unsupported Canvas.drawBitmap overload');
            }
            graphics.draw(this._bitmap._handle, bitmap._handle, source, destination, !!(paint && paint._filtered));
        };
    """#
}
