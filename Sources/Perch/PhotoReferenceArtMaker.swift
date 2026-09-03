import CoreImage
import ImageIO
import PerchCore
import UniformTypeIdentifiers
import Vision

enum PhotoReferenceArtError: Error {
    case unreadableImage
    case noSubjectFound
    case cannotWrite
}

/// Turns a user-chosen photo into clean, transparent reference art for the
/// perch-pet skill, fully on device: the subject is lifted with Vision and
/// only the composed reference PNG is written. Nothing is uploaded and the
/// original photo is never copied.
enum PhotoReferenceArtMaker {
    private static let maximumInputBytes = 50 * 1_024 * 1_024
    private static let maximumDecodedDimension = 4_096

    static func makeReferenceArt(
        from sourceURL: URL,
        outputDirectory: URL
    ) throws -> URL {
        guard let values = try? sourceURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= maximumInputBytes,
              let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  imageSource,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumDecodedDimension,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else {
            throw PhotoReferenceArtError.unreadableImage
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([request])
        } catch {
            throw PhotoReferenceArtError.noSubjectFound
        }
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let subjectBuffer = try? observation.generateMaskedImage(
                  ofInstances: observation.allInstances,
                  from: handler,
                  croppedToInstancesExtent: true
              ) else {
            throw PhotoReferenceArtError.noSubjectFound
        }

        let subject = CIImage(cvPixelBuffer: subjectBuffer)
        let ciContext = CIContext()
        guard let subjectImage = ciContext.createCGImage(
            subject,
            from: subject.extent
        ), let placement = ReferenceArtComposition.placement(
            subjectWidth: Double(subjectImage.width),
            subjectHeight: Double(subjectImage.height)
        ) else {
            throw PhotoReferenceArtError.noSubjectFound
        }

        let side = Int(ReferenceArtComposition.canvasSide)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw PhotoReferenceArtError.cannotWrite
        }
        canvas.interpolationQuality = .high
        canvas.draw(subjectImage, in: CGRect(
            x: placement.x,
            y: placement.y,
            width: placement.width,
            height: placement.height
        ))
        guard let composed = canvas.makeImage() else {
            throw PhotoReferenceArtError.cannotWrite
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        var base = String(
            sourceURL.deletingPathExtension().lastPathComponent.prefix(40)
        )
        if base.isEmpty { base = "photo" }
        var outputURL = outputDirectory
            .appendingPathComponent(base + "-perch-reference.png")
        var counter = 2
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = outputDirectory
                .appendingPathComponent(base + "-perch-reference-\(counter).png")
            counter += 1
        }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoReferenceArtError.cannotWrite
        }
        CGImageDestinationAddImage(destination, composed, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoReferenceArtError.cannotWrite
        }
        return outputURL
    }
}
