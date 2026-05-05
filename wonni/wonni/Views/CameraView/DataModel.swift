/*
See the License.txt file for this sample’s licensing information.
*/

import AVFoundation
import SwiftUI
import os.log

final class DataModel: ObservableObject {
    let camera = Camera()
    let photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)
    
    @Published var viewfinderImage: Image?
    @Published var thumbnailImage: Image?
    
    //@Published var to hold data for photos taken during session
    @Published var sessionPhotos: [[UIImage]] = []
    
    var isPhotosLoaded = false
    
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
            Task { @MainActor in
                // MARK: does it make more sense to change thumbnailImage to static image?
                thumbnailImage = photoData.thumbnailImage
                
                // Convert the captured photo data to UIImage and add it to the sessionPhotos array
                if let uiImage = UIImage(data: photoData.imageData) {
                    // If sessionPhotos is empty or the last stack is empty (user created new stack)
                    if sessionPhotos.isEmpty || sessionPhotos[sessionPhotos.count - 1].isEmpty {
                        sessionPhotos.append([uiImage]) // Create a new stack
                    } else {
                        sessionPhotos[sessionPhotos.count - 1].append(uiImage) // Add to the last stack
                    }
                }
            }
            savePhoto(imageData: photoData.imageData)
        }
    }
    
    // Add a new empty stack to sessionPhotos, if last stack is not empty
    func addNewStack() {
        if sessionPhotos.isEmpty || !sessionPhotos[sessionPhotos.count - 1].isEmpty {
            sessionPhotos.append([]) // Append an empty array to create a new stack
        }
    }
    
    // Move photo within the same stack
    func movePhotoWithinStack(stackIndex: Int, from: Int, to: Int) {
        // safe guard that stackIndex is within bounds of the number of stacks we have
        // safe guard that to and from are within bounds of the current stack
        guard stackIndex < sessionPhotos.count,
              from < sessionPhotos[stackIndex].count,
              to < sessionPhotos[stackIndex].count else { return }
        
        let photo = sessionPhotos[stackIndex].remove(at: from)
        sessionPhotos[stackIndex].insert(photo, at: to)
    }
    
    // Move photo between different stacks
    func movePhotoBetweenStacks(fromStack: Int, fromIndex: Int, toStack: Int, toIndex: Int) {
        // safe guard that both stacks are within bounds of the number of stacks we have
        // safe guard that to and from are within bounds of the respective stacks
        guard fromStack < sessionPhotos.count,
              toStack < sessionPhotos.count,
              fromIndex < sessionPhotos[fromStack].count,
              toIndex <= sessionPhotos[toStack].count else { return }
        
        let photo = sessionPhotos[fromStack].remove(at: fromIndex)
        sessionPhotos[toStack].insert(photo, at: toIndex)
    }
    
    // Remove photo from stack
    func removePhoto(stackIndex: Int, photoIndex: Int) {
        // safe guard that stack is within bounds of the number of stacks we have
        // safe guard that photo is within bounds of the stack selected
        guard stackIndex < sessionPhotos.count,
              photoIndex < sessionPhotos[stackIndex].count else { return }
        
        sessionPhotos[stackIndex].remove(at: photoIndex)
        
        // Remove empty stacks
        sessionPhotos.removeAll { $0.isEmpty }
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
    
    func savePhoto(imageData: Data) {
        Task {
            do {
                try await photoCollection.addImage(imageData)
                logger.debug("Added image data to photo collection.")
            } catch let error {
                logger.error("Failed to add image to photo collection: \(error.localizedDescription)")
            }
        }
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
        guard let asset = photoCollection.photoAssets.first  else { return }
        await photoCollection.cache.requestImage(for: asset, targetSize: CGSize(width: 256, height: 256))  { result in
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
