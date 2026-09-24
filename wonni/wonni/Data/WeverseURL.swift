//
//  WeverseURL.swift
//  wonni
//

import Foundation

// Mirrors functions/weverse_shop.js's parseWeverseUrl: a sale page is
// …/artists/{id}/sales/{id}. Shared by ImportListingSheet, BulkImportSheet,
// and the shipping probe so the pattern lives in exactly one place.
func weverseSaleId(from urlString: String) -> String? {
    guard let range = urlString.range(of: #"/artists/\d+/sales/(\d+)"#, options: .regularExpression) else {
        return nil
    }
    let match = String(urlString[range])
    return match.components(separatedBy: "/sales/").last
}
