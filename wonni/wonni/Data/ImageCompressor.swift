//
//  ImageCompressor.swift
//  wonni
//
//  Handles on-device image compression to target file size (e.g. 150 KB)
//  to save on Firebase Storage costs and speed up Gemini processing.
//

import UIKit

struct ImageCompressor {
    
    /// Compresses a UIImage to a target size in bytes.
    /// Uses binary search to find the best compression quality.
    static func compress(image: UIImage, targetSizeInBytes: Int = 150 * 1024) -> Data? {
        var compression: CGFloat = 1.0
        var max: CGFloat = 1.0
        var min: CGFloat = 0.0
        
        // Initial attempt at 1.0 quality
        guard var data = image.jpegData(compressionQuality: compression) else { return nil }
        
        if data.count <= targetSizeInBytes {
            return data
        }
        
        // Binary search for quality (6 iterations is usually enough for 0.01 precision)
        for _ in 0..<6 {
            compression = (max + min) / 2
            if let newData = image.jpegData(compressionQuality: compression) {
                data = newData
                if newData.count < targetSizeInBytes {
                    min = compression
                } else {
                    max = compression
                }
            }
        }
        
        return data
    }
    
    /// Resizes an image to a maximum dimension while maintaining aspect ratio.
    static func resize(image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let size = image.size
        let widthRatio  = maxDimension / size.width
        let heightRatio = maxDimension / size.height
        
        let ratio = min(widthRatio, heightRatio)
        if ratio >= 1.0 { return image } // Already smaller
        
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let rect = CGRect(origin: .zero, size: newSize)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: rect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return newImage ?? image
    }
}
