import CoreGraphics
import Foundation
import ImageIO

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Prepares images for efficient model consumption by resizing large images.
///
/// Camera images are often 4000×3000+ pixels, far larger than what on-device LLMs need.
/// Use `ImageProcessor` to resize images before sending them to the model, reducing
/// memory usage and improving inference speed.
///
/// ```swift
/// let photoData: Data = ... // 4032×3024 camera image
/// let resized = try ImageProcessor.resize(photoData)  // → 1024×768 JPEG
/// let reply = try await conversation.sendMessage(
///     Contents.of(.imageBytes(resized), .text("What's in this photo?"))
/// )
/// ```
///
/// Images that are already within the size limit are returned unchanged (no recompression).
public enum ImageProcessor {

    /// Default maximum dimension (longest edge) for resized images.
    public static let defaultMaxDimension = 1024

    /// Default JPEG compression quality for resized images.
    public static let defaultJPEGQuality = 0.85

    // MARK: - Resize from Data

    /// Resizes an image if its longest edge exceeds `maxDimension`.
    ///
    /// If the image already fits within `maxDimension`, the original data is returned
    /// unchanged to avoid unnecessary recompression.
    ///
    /// - Parameters:
    ///   - imageData: Raw image data (JPEG, PNG, HEIC, etc.).
    ///   - maxDimension: Maximum allowed size for the longest edge, in pixels. Default: 1024.
    ///   - jpegQuality: JPEG compression quality (0.0–1.0) when resizing is needed. Default: 0.85.
    /// - Returns: The (possibly resized) image data.
    /// - Throws: ``ImageProcessorError/unsupportedFormat`` if the image cannot be decoded.
    public static func resize(
        _ imageData: Data,
        maxDimension: Int = defaultMaxDimension,
        jpegQuality: Double = defaultJPEGQuality
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageProcessorError.unsupportedFormat
        }

        let width = cgImage.width
        let height = cgImage.height

        // Already small enough — return original data without recompression
        if max(width, height) <= maxDimension {
            return imageData
        }

        return try resizeCGImage(cgImage, maxDimension: maxDimension, jpegQuality: jpegQuality)
    }

    // MARK: - Resize from URL

    /// Resizes an image file if its longest edge exceeds `maxDimension`.
    ///
    /// - Parameters:
    ///   - url: File URL of the image.
    ///   - maxDimension: Maximum allowed size for the longest edge, in pixels. Default: 1024.
    ///   - jpegQuality: JPEG compression quality (0.0–1.0) when resizing is needed. Default: 0.85.
    /// - Returns: The (possibly resized) image data.
    /// - Throws: ``ImageProcessorError/unsupportedFormat`` if the image cannot be decoded,
    ///           or a file-system error if the file cannot be read.
    public static func resize(
        contentsOf url: URL,
        maxDimension: Int = defaultMaxDimension,
        jpegQuality: Double = defaultJPEGQuality
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageProcessorError.unsupportedFormat
        }

        let width = cgImage.width
        let height = cgImage.height

        if max(width, height) <= maxDimension {
            return try Data(contentsOf: url)
        }

        return try resizeCGImage(cgImage, maxDimension: maxDimension, jpegQuality: jpegQuality)
    }

    // MARK: - Dimensions

    /// Returns the pixel dimensions of an image without fully decoding it.
    ///
    /// - Parameter imageData: Raw image data.
    /// - Returns: The image size in pixels, or `nil` if the format is not recognized.
    public static func dimensions(of imageData: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    // MARK: - Private

    private static func resizeCGImage(
        _ cgImage: CGImage,
        maxDimension: Int,
        jpegQuality: Double
    ) throws -> Data {
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let longestEdge = max(originalWidth, originalHeight)
        let scale = Double(maxDimension) / Double(longestEdge)
        let newWidth = Int(Double(originalWidth) * scale)
        let newHeight = Int(Double(originalHeight) * scale)

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: newWidth,
                  height: newHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ImageProcessorError.resizeFailed
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resizedImage = context.makeImage() else {
            throw ImageProcessorError.resizeFailed
        }

        // Export as JPEG
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw ImageProcessorError.resizeFailed
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(destination, resizedImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessorError.resizeFailed
        }

        return data as Data
    }
}

// MARK: - Errors

/// Errors thrown by ``ImageProcessor``.
public enum ImageProcessorError: Error, LocalizedError, Sendable {
    /// The image data format is not recognized or cannot be decoded.
    case unsupportedFormat
    /// The image could not be resized (e.g., failed to create graphics context).
    case resizeFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Unsupported image format — expected JPEG, PNG, HEIC, or other CGImageSource-compatible format"
        case .resizeFailed:
            "Failed to resize the image"
        }
    }
}
