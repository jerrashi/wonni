/*
See the License.txt file for this sample's licensing information.
*/

import AVFoundation
import SwiftUI
import os.log
import SwiftData

final class DataModel: ObservableObject, @unchecked Sendable {
    let camera = Camera()
    let photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)

    @Published var viewfinderImage: Image?
    @Published var thumbnailImage: Image?

    var isPhotosLoaded = false

    /// Set by CameraView before camera starts. Called on MainActor after each
    /// photo is saved, with the asset ID and raw image data.
    var onPhotoAdded: ((String, Data) -> Void)?

    init() {
        Task {
            await handleCameraPreviews()
        }

        Task {
            await handleCameraPhotos()
        }
    }

    func handleCameraPreviews() async {
        let imageStream = camera.previewStream
            .map { $0.image }

        for await image in imageStream {
            Task { @MainActor in
                viewfinderImage = image
            }
        }
    }

    func handleCameraPhotos() async {
        let unpackedPhotoStream = camera.photoStream
            .compactMap { self.unpackPhoto($0) }

        for await photoData in unpackedPhotoStream {
            let assetId = await savePhoto(imageData: photoData.imageData)

            Task { @MainActor in
                thumbnailImage = photoData.thumbnailImage
                onPhotoAdded?(assetId, photoData.imageData)
            }
        }
    }

    private func unpackPhoto(_ photo: AVCapturePhoto) -> PhotoData? {
        guard let imageData = photo.fileDataRepresentation() else { return nil }

        guard let previewCGImage = photo.previewCGImageRepresentation(),
           let metadataOrientation = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32,
              let cgImageOrientation = CGImagePropertyOrientation(rawValue: metadataOrientation) else { return nil }
        let imageOrientation = Image.Orientation(cgImageOrientation)
        let thumbnailImage = Image(decorative: previewCGImage, scale: 1, orientation: imageOrientation)

        let photoDimensions = photo.resolvedSettings.photoDimensions
        let imageSize = (width: Int(photoDimensions.width), height: Int(photoDimensions.height))
        let previewDimensions = photo.resolvedSettings.previewDimensions
        let thumbnailSize = (width: Int(previewDimensions.width), height: Int(previewDimensions.height))

        return PhotoData(thumbnailImage: thumbnailImage, thumbnailSize: thumbnailSize, imageData: imageData, imageSize: imageSize)
    }

    func savePhoto(imageData: Data) async -> String {
        let saveToCameraRoll = UserDefaults.standard.object(forKey: "saveToCameraRoll") as? Bool ?? true
        if saveToCameraRoll {
            do {
                let assetId = try await photoCollection.addImage(imageData)
                logger.debug("Added image data to photo collection with asset ID: \(assetId)")
                return assetId
            } catch let error {
                logger.error("Failed to add image to photo collection: \(error.localizedDescription)")
                // Fall through to local ID on failure
            }
        }
        // Local-only path (saveToCameraRoll=false or photo library save failed)
        return "local_temp_" + UUID().uuidString
    }

    func loadPhotos() async {
        guard !isPhotosLoaded else { return }

        let authorized = await PhotoLibrary.checkAuthorization()
        guard authorized else {
            logger.error("Photo library access was not authorized.")
            return
        }

        Task {
            do {
                try await self.photoCollection.load()
                await self.loadThumbnail()
            } catch let error {
                logger.error("Failed to load photo collection: \(error.localizedDescription)")
            }
            self.isPhotosLoaded = true
        }
    }

    func loadThumbnail() async {
        guard let asset = photoCollection.photoAssets.first else { return }
        await photoCollection.cache.requestImage(for: asset, targetSize: CGSize(width: 256, height: 256)) { result in
            if let result = result {
                Task { @MainActor in
                    self.thumbnailImage = result.image
                }
            }
        }
    }
}

fileprivate struct PhotoData {
    var thumbnailImage: Image
    var thumbnailSize: (width: Int, height: Int)
    var imageData: Data
    var imageSize: (width: Int, height: Int)
}

fileprivate extension CIImage {
    var image: Image? {
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(self, from: self.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}

fileprivate extension Image.Orientation {

    init(_ cgImageOrientation: CGImagePropertyOrientation) {
        switch cgImageOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        }
    }
}

fileprivate let logger = Logger(subsystem: "com.apple.swiftplaygroundscontent.capturingphotos", category: "DataModel")
