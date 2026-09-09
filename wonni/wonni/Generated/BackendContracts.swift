// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let backendContracts = try BackendContracts(json)

import Foundation

/// Generated from functions/contracts/. Do not edit by hand.
// MARK: - BackendContracts
struct BackendContracts: Codable, Sendable {
    let decrementAndCascadeRequest: DecrementAndCascadeRequest?
    let decrementAndCascadeResponse: DecrementAndCascadeResponse?
    let detectMercariPullSyncDiffRequest: DetectMercariPullSyncDiffRequest?
    let detectMercariPullSyncDiffResponse: DetectMercariPullSyncDiffResponse?
    let ebayApplyDriftRequest: EbayApplyDriftRequest?
    let ebayApplyDriftResponse: EbayApplyDriftResponse?
    let ebayCheckDriftRequest: EbayCheckDriftRequest?
    let ebayCheckDriftResponse: EbayCheckDriftResponse?
    let ebayCreateListingRequest: EbayCreateListingRequest?
    let ebayCreateListingResponse: EbayCreateListingResponse?
    let ebayDeleteListingRequest: EbayDeleteListingRequest?
    let ebayDeleteListingResponse: EbayDeleteListingResponse?
    let ebayGetListingRequest: EbayGetListingRequest?
    let ebayGetListingResponse: EbayGetListingResponse?
    let ebayImportListingRequest: EbayImportListingRequest?
    let ebayImportListingResponse: EbayImportListingResponse?
    let ebayUpdateListingRequest: EbayUpdateListingRequest?
    let ebayUpdateListingResponse: EbayUpdateListingResponse?
    let enrichListingRequest: EnrichListingRequest?
    let enrichListingResponse: EnrichListingResponse?
    let etsyCheckShopSetupRequest: EtsyCheckShopSetupRequest?
    let etsyCheckShopSetupResponse: EtsyCheckShopSetupResponse?
    let etsyCreateListingRequest: EtsyCreateListingRequest?
    let etsyCreateListingResponse: EtsyCreateListingResponse?
    let etsyDeleteListingRequest: EtsyDeleteListingRequest?
    let etsyDeleteListingResponse: EtsyDeleteListingResponse?
    let etsyImportPullSyncRequest: EtsyImportPullSyncRequest?
    let etsyImportPullSyncResponse: EtsyImportPullSyncResponse?
    let etsyPullSyncRequest: EtsyPullSyncRequest?
    let etsyPullSyncResponse: EtsyPullSyncResponse?
    let etsyUpdateListingRequest: EtsyUpdateListingRequest?
    let etsyUpdateListingResponse: EtsyUpdateListingResponse?
    let getEtsyCategoriesRequest: GetEtsyCategoriesRequest?
    let getEtsyCategoriesResponse: GetEtsyCategoriesResponse?
    let getEtsyReturnPoliciesRequest: GetEtsyReturnPoliciesRequest?
    let getEtsyReturnPoliciesResponse: GetEtsyReturnPoliciesResponse?
    let getEtsyShippingProfilesRequest: GetEtsyShippingProfilesRequest?
    let getEtsyShippingProfilesResponse: GetEtsyShippingProfilesResponse?
    let getOrderTakeHomeRequest: GetOrderTakeHomeRequest?
    let getOrderTakeHomeResponse: GetOrderTakeHomeResponse?
    let importMercariPullSyncRequest: ImportMercariPullSyncRequest?
    let importMercariPullSyncResponse: ImportMercariPullSyncResponse?
    let listingFields: ListingFields?
    let markSoldOutAndCascadeRequest: MarkSoldOutAndCascadeRequest?
    let markSoldOutAndCascadeResponse: MarkSoldOutAndCascadeResponse?
    let mercariScrapeItem: MercariScrapeItem?
    let recordMercariSalesBatchRequest: RecordMercariSalesBatchRequest?
    let recordMercariSalesBatchResponse: RecordMercariSalesBatchResponse?
    let recordSaleRequest: RecordSaleRequest?
    let recordSaleResponse: RecordSaleResponse?
    let restockAndCascadeRequest: RestockAndCascadeRequest?
    let restockAndCascadeResponse: RestockAndCascadeResponse?
    let saleDoc: SaleDoc?
    let suggestEtsyCategoryRequest: SuggestEtsyCategoryRequest?
    let suggestEtsyCategoryResponse: SuggestEtsyCategoryResponse?
    let syncSalesRequest: SyncSalesRequest?
    let syncSalesResponse: SyncSalesResponse?
    let updateMercariListingStatusRequest: UpdateMercariListingStatusRequest?
    let updateMercariListingStatusResponse: UpdateMercariListingStatusResponse?

    enum CodingKeys: String, CodingKey {
        case decrementAndCascadeRequest = "DecrementAndCascadeRequest"
        case decrementAndCascadeResponse = "DecrementAndCascadeResponse"
        case detectMercariPullSyncDiffRequest = "DetectMercariPullSyncDiffRequest"
        case detectMercariPullSyncDiffResponse = "DetectMercariPullSyncDiffResponse"
        case ebayApplyDriftRequest = "EbayApplyDriftRequest"
        case ebayApplyDriftResponse = "EbayApplyDriftResponse"
        case ebayCheckDriftRequest = "EbayCheckDriftRequest"
        case ebayCheckDriftResponse = "EbayCheckDriftResponse"
        case ebayCreateListingRequest = "EbayCreateListingRequest"
        case ebayCreateListingResponse = "EbayCreateListingResponse"
        case ebayDeleteListingRequest = "EbayDeleteListingRequest"
        case ebayDeleteListingResponse = "EbayDeleteListingResponse"
        case ebayGetListingRequest = "EbayGetListingRequest"
        case ebayGetListingResponse = "EbayGetListingResponse"
        case ebayImportListingRequest = "EbayImportListingRequest"
        case ebayImportListingResponse = "EbayImportListingResponse"
        case ebayUpdateListingRequest = "EbayUpdateListingRequest"
        case ebayUpdateListingResponse = "EbayUpdateListingResponse"
        case enrichListingRequest = "EnrichListingRequest"
        case enrichListingResponse = "EnrichListingResponse"
        case etsyCheckShopSetupRequest = "EtsyCheckShopSetupRequest"
        case etsyCheckShopSetupResponse = "EtsyCheckShopSetupResponse"
        case etsyCreateListingRequest = "EtsyCreateListingRequest"
        case etsyCreateListingResponse = "EtsyCreateListingResponse"
        case etsyDeleteListingRequest = "EtsyDeleteListingRequest"
        case etsyDeleteListingResponse = "EtsyDeleteListingResponse"
        case etsyImportPullSyncRequest = "EtsyImportPullSyncRequest"
        case etsyImportPullSyncResponse = "EtsyImportPullSyncResponse"
        case etsyPullSyncRequest = "EtsyPullSyncRequest"
        case etsyPullSyncResponse = "EtsyPullSyncResponse"
        case etsyUpdateListingRequest = "EtsyUpdateListingRequest"
        case etsyUpdateListingResponse = "EtsyUpdateListingResponse"
        case getEtsyCategoriesRequest = "GetEtsyCategoriesRequest"
        case getEtsyCategoriesResponse = "GetEtsyCategoriesResponse"
        case getEtsyReturnPoliciesRequest = "GetEtsyReturnPoliciesRequest"
        case getEtsyReturnPoliciesResponse = "GetEtsyReturnPoliciesResponse"
        case getEtsyShippingProfilesRequest = "GetEtsyShippingProfilesRequest"
        case getEtsyShippingProfilesResponse = "GetEtsyShippingProfilesResponse"
        case getOrderTakeHomeRequest = "GetOrderTakeHomeRequest"
        case getOrderTakeHomeResponse = "GetOrderTakeHomeResponse"
        case importMercariPullSyncRequest = "ImportMercariPullSyncRequest"
        case importMercariPullSyncResponse = "ImportMercariPullSyncResponse"
        case listingFields = "ListingFields"
        case markSoldOutAndCascadeRequest = "MarkSoldOutAndCascadeRequest"
        case markSoldOutAndCascadeResponse = "MarkSoldOutAndCascadeResponse"
        case mercariScrapeItem = "MercariScrapeItem"
        case recordMercariSalesBatchRequest = "RecordMercariSalesBatchRequest"
        case recordMercariSalesBatchResponse = "RecordMercariSalesBatchResponse"
        case recordSaleRequest = "RecordSaleRequest"
        case recordSaleResponse = "RecordSaleResponse"
        case restockAndCascadeRequest = "RestockAndCascadeRequest"
        case restockAndCascadeResponse = "RestockAndCascadeResponse"
        case saleDoc = "SaleDoc"
        case suggestEtsyCategoryRequest = "SuggestEtsyCategoryRequest"
        case suggestEtsyCategoryResponse = "SuggestEtsyCategoryResponse"
        case syncSalesRequest = "SyncSalesRequest"
        case syncSalesResponse = "SyncSalesResponse"
        case updateMercariListingStatusRequest = "UpdateMercariListingStatusRequest"
        case updateMercariListingStatusResponse = "UpdateMercariListingStatusResponse"
    }
}

// MARK: BackendContracts convenience initializers and mutators

extension BackendContracts {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(BackendContracts.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        decrementAndCascadeRequest: DecrementAndCascadeRequest?? = nil,
        decrementAndCascadeResponse: DecrementAndCascadeResponse?? = nil,
        detectMercariPullSyncDiffRequest: DetectMercariPullSyncDiffRequest?? = nil,
        detectMercariPullSyncDiffResponse: DetectMercariPullSyncDiffResponse?? = nil,
        ebayApplyDriftRequest: EbayApplyDriftRequest?? = nil,
        ebayApplyDriftResponse: EbayApplyDriftResponse?? = nil,
        ebayCheckDriftRequest: EbayCheckDriftRequest?? = nil,
        ebayCheckDriftResponse: EbayCheckDriftResponse?? = nil,
        ebayCreateListingRequest: EbayCreateListingRequest?? = nil,
        ebayCreateListingResponse: EbayCreateListingResponse?? = nil,
        ebayDeleteListingRequest: EbayDeleteListingRequest?? = nil,
        ebayDeleteListingResponse: EbayDeleteListingResponse?? = nil,
        ebayGetListingRequest: EbayGetListingRequest?? = nil,
        ebayGetListingResponse: EbayGetListingResponse?? = nil,
        ebayImportListingRequest: EbayImportListingRequest?? = nil,
        ebayImportListingResponse: EbayImportListingResponse?? = nil,
        ebayUpdateListingRequest: EbayUpdateListingRequest?? = nil,
        ebayUpdateListingResponse: EbayUpdateListingResponse?? = nil,
        enrichListingRequest: EnrichListingRequest?? = nil,
        enrichListingResponse: EnrichListingResponse?? = nil,
        etsyCheckShopSetupRequest: EtsyCheckShopSetupRequest?? = nil,
        etsyCheckShopSetupResponse: EtsyCheckShopSetupResponse?? = nil,
        etsyCreateListingRequest: EtsyCreateListingRequest?? = nil,
        etsyCreateListingResponse: EtsyCreateListingResponse?? = nil,
        etsyDeleteListingRequest: EtsyDeleteListingRequest?? = nil,
        etsyDeleteListingResponse: EtsyDeleteListingResponse?? = nil,
        etsyImportPullSyncRequest: EtsyImportPullSyncRequest?? = nil,
        etsyImportPullSyncResponse: EtsyImportPullSyncResponse?? = nil,
        etsyPullSyncRequest: EtsyPullSyncRequest?? = nil,
        etsyPullSyncResponse: EtsyPullSyncResponse?? = nil,
        etsyUpdateListingRequest: EtsyUpdateListingRequest?? = nil,
        etsyUpdateListingResponse: EtsyUpdateListingResponse?? = nil,
        getEtsyCategoriesRequest: GetEtsyCategoriesRequest?? = nil,
        getEtsyCategoriesResponse: GetEtsyCategoriesResponse?? = nil,
        getEtsyReturnPoliciesRequest: GetEtsyReturnPoliciesRequest?? = nil,
        getEtsyReturnPoliciesResponse: GetEtsyReturnPoliciesResponse?? = nil,
        getEtsyShippingProfilesRequest: GetEtsyShippingProfilesRequest?? = nil,
        getEtsyShippingProfilesResponse: GetEtsyShippingProfilesResponse?? = nil,
        getOrderTakeHomeRequest: GetOrderTakeHomeRequest?? = nil,
        getOrderTakeHomeResponse: GetOrderTakeHomeResponse?? = nil,
        importMercariPullSyncRequest: ImportMercariPullSyncRequest?? = nil,
        importMercariPullSyncResponse: ImportMercariPullSyncResponse?? = nil,
        listingFields: ListingFields?? = nil,
        markSoldOutAndCascadeRequest: MarkSoldOutAndCascadeRequest?? = nil,
        markSoldOutAndCascadeResponse: MarkSoldOutAndCascadeResponse?? = nil,
        mercariScrapeItem: MercariScrapeItem?? = nil,
        recordMercariSalesBatchRequest: RecordMercariSalesBatchRequest?? = nil,
        recordMercariSalesBatchResponse: RecordMercariSalesBatchResponse?? = nil,
        recordSaleRequest: RecordSaleRequest?? = nil,
        recordSaleResponse: RecordSaleResponse?? = nil,
        restockAndCascadeRequest: RestockAndCascadeRequest?? = nil,
        restockAndCascadeResponse: RestockAndCascadeResponse?? = nil,
        saleDoc: SaleDoc?? = nil,
        suggestEtsyCategoryRequest: SuggestEtsyCategoryRequest?? = nil,
        suggestEtsyCategoryResponse: SuggestEtsyCategoryResponse?? = nil,
        syncSalesRequest: SyncSalesRequest?? = nil,
        syncSalesResponse: SyncSalesResponse?? = nil,
        updateMercariListingStatusRequest: UpdateMercariListingStatusRequest?? = nil,
        updateMercariListingStatusResponse: UpdateMercariListingStatusResponse?? = nil
    ) -> BackendContracts {
        return BackendContracts(
            decrementAndCascadeRequest: decrementAndCascadeRequest ?? self.decrementAndCascadeRequest,
            decrementAndCascadeResponse: decrementAndCascadeResponse ?? self.decrementAndCascadeResponse,
            detectMercariPullSyncDiffRequest: detectMercariPullSyncDiffRequest ?? self.detectMercariPullSyncDiffRequest,
            detectMercariPullSyncDiffResponse: detectMercariPullSyncDiffResponse ?? self.detectMercariPullSyncDiffResponse,
            ebayApplyDriftRequest: ebayApplyDriftRequest ?? self.ebayApplyDriftRequest,
            ebayApplyDriftResponse: ebayApplyDriftResponse ?? self.ebayApplyDriftResponse,
            ebayCheckDriftRequest: ebayCheckDriftRequest ?? self.ebayCheckDriftRequest,
            ebayCheckDriftResponse: ebayCheckDriftResponse ?? self.ebayCheckDriftResponse,
            ebayCreateListingRequest: ebayCreateListingRequest ?? self.ebayCreateListingRequest,
            ebayCreateListingResponse: ebayCreateListingResponse ?? self.ebayCreateListingResponse,
            ebayDeleteListingRequest: ebayDeleteListingRequest ?? self.ebayDeleteListingRequest,
            ebayDeleteListingResponse: ebayDeleteListingResponse ?? self.ebayDeleteListingResponse,
            ebayGetListingRequest: ebayGetListingRequest ?? self.ebayGetListingRequest,
            ebayGetListingResponse: ebayGetListingResponse ?? self.ebayGetListingResponse,
            ebayImportListingRequest: ebayImportListingRequest ?? self.ebayImportListingRequest,
            ebayImportListingResponse: ebayImportListingResponse ?? self.ebayImportListingResponse,
            ebayUpdateListingRequest: ebayUpdateListingRequest ?? self.ebayUpdateListingRequest,
            ebayUpdateListingResponse: ebayUpdateListingResponse ?? self.ebayUpdateListingResponse,
            enrichListingRequest: enrichListingRequest ?? self.enrichListingRequest,
            enrichListingResponse: enrichListingResponse ?? self.enrichListingResponse,
            etsyCheckShopSetupRequest: etsyCheckShopSetupRequest ?? self.etsyCheckShopSetupRequest,
            etsyCheckShopSetupResponse: etsyCheckShopSetupResponse ?? self.etsyCheckShopSetupResponse,
            etsyCreateListingRequest: etsyCreateListingRequest ?? self.etsyCreateListingRequest,
            etsyCreateListingResponse: etsyCreateListingResponse ?? self.etsyCreateListingResponse,
            etsyDeleteListingRequest: etsyDeleteListingRequest ?? self.etsyDeleteListingRequest,
            etsyDeleteListingResponse: etsyDeleteListingResponse ?? self.etsyDeleteListingResponse,
            etsyImportPullSyncRequest: etsyImportPullSyncRequest ?? self.etsyImportPullSyncRequest,
            etsyImportPullSyncResponse: etsyImportPullSyncResponse ?? self.etsyImportPullSyncResponse,
            etsyPullSyncRequest: etsyPullSyncRequest ?? self.etsyPullSyncRequest,
            etsyPullSyncResponse: etsyPullSyncResponse ?? self.etsyPullSyncResponse,
            etsyUpdateListingRequest: etsyUpdateListingRequest ?? self.etsyUpdateListingRequest,
            etsyUpdateListingResponse: etsyUpdateListingResponse ?? self.etsyUpdateListingResponse,
            getEtsyCategoriesRequest: getEtsyCategoriesRequest ?? self.getEtsyCategoriesRequest,
            getEtsyCategoriesResponse: getEtsyCategoriesResponse ?? self.getEtsyCategoriesResponse,
            getEtsyReturnPoliciesRequest: getEtsyReturnPoliciesRequest ?? self.getEtsyReturnPoliciesRequest,
            getEtsyReturnPoliciesResponse: getEtsyReturnPoliciesResponse ?? self.getEtsyReturnPoliciesResponse,
            getEtsyShippingProfilesRequest: getEtsyShippingProfilesRequest ?? self.getEtsyShippingProfilesRequest,
            getEtsyShippingProfilesResponse: getEtsyShippingProfilesResponse ?? self.getEtsyShippingProfilesResponse,
            getOrderTakeHomeRequest: getOrderTakeHomeRequest ?? self.getOrderTakeHomeRequest,
            getOrderTakeHomeResponse: getOrderTakeHomeResponse ?? self.getOrderTakeHomeResponse,
            importMercariPullSyncRequest: importMercariPullSyncRequest ?? self.importMercariPullSyncRequest,
            importMercariPullSyncResponse: importMercariPullSyncResponse ?? self.importMercariPullSyncResponse,
            listingFields: listingFields ?? self.listingFields,
            markSoldOutAndCascadeRequest: markSoldOutAndCascadeRequest ?? self.markSoldOutAndCascadeRequest,
            markSoldOutAndCascadeResponse: markSoldOutAndCascadeResponse ?? self.markSoldOutAndCascadeResponse,
            mercariScrapeItem: mercariScrapeItem ?? self.mercariScrapeItem,
            recordMercariSalesBatchRequest: recordMercariSalesBatchRequest ?? self.recordMercariSalesBatchRequest,
            recordMercariSalesBatchResponse: recordMercariSalesBatchResponse ?? self.recordMercariSalesBatchResponse,
            recordSaleRequest: recordSaleRequest ?? self.recordSaleRequest,
            recordSaleResponse: recordSaleResponse ?? self.recordSaleResponse,
            restockAndCascadeRequest: restockAndCascadeRequest ?? self.restockAndCascadeRequest,
            restockAndCascadeResponse: restockAndCascadeResponse ?? self.restockAndCascadeResponse,
            saleDoc: saleDoc ?? self.saleDoc,
            suggestEtsyCategoryRequest: suggestEtsyCategoryRequest ?? self.suggestEtsyCategoryRequest,
            suggestEtsyCategoryResponse: suggestEtsyCategoryResponse ?? self.suggestEtsyCategoryResponse,
            syncSalesRequest: syncSalesRequest ?? self.syncSalesRequest,
            syncSalesResponse: syncSalesResponse ?? self.syncSalesResponse,
            updateMercariListingStatusRequest: updateMercariListingStatusRequest ?? self.updateMercariListingStatusRequest,
            updateMercariListingStatusResponse: updateMercariListingStatusResponse ?? self.updateMercariListingStatusResponse
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - DecrementAndCascadeRequest
struct DecrementAndCascadeRequest: Codable, Sendable {
    let platform: DecrementAndCascadeRequestPlatform
    let productId: String
    let variantSku: String?

    enum CodingKeys: String, CodingKey {
        case platform = "platform"
        case productId = "productId"
        case variantSku = "variantSku"
    }
}

// MARK: DecrementAndCascadeRequest convenience initializers and mutators

extension DecrementAndCascadeRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DecrementAndCascadeRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        platform: DecrementAndCascadeRequestPlatform? = nil,
        productId: String? = nil,
        variantSku: String?? = nil
    ) -> DecrementAndCascadeRequest {
        return DecrementAndCascadeRequest(
            platform: platform ?? self.platform,
            productId: productId ?? self.productId,
            variantSku: variantSku ?? self.variantSku
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum DecrementAndCascadeRequestPlatform: String, Codable, Sendable {
    case ebay = "ebay"
    case etsy = "etsy"
    case manual = "manual"
    case mercari = "mercari"
    case tiktok = "tiktok"
    case wonni = "wonni"
}

// MARK: - DecrementAndCascadeResponse
struct DecrementAndCascadeResponse: Codable, Sendable {
    let cascade: DecrementAndCascadeResponseCascade
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case cascade = "cascade"
        case success = "success"
    }
}

// MARK: DecrementAndCascadeResponse convenience initializers and mutators

extension DecrementAndCascadeResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DecrementAndCascadeResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        cascade: DecrementAndCascadeResponseCascade? = nil,
        success: Bool? = nil
    ) -> DecrementAndCascadeResponse {
        return DecrementAndCascadeResponse(
            cascade: cascade ?? self.cascade,
            success: success ?? self.success
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - DecrementAndCascadeResponseCascade
struct DecrementAndCascadeResponseCascade: Codable, Sendable {
    let newQuantity: Int?
    let platforms: [String: PlatformValue]
    let previousQuantity: Int?
    let productId: String?
    let soldOut: Bool

    enum CodingKeys: String, CodingKey {
        case newQuantity = "newQuantity"
        case platforms = "platforms"
        case previousQuantity = "previousQuantity"
        case productId = "productId"
        case soldOut = "soldOut"
    }
}

// MARK: DecrementAndCascadeResponseCascade convenience initializers and mutators

extension DecrementAndCascadeResponseCascade {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DecrementAndCascadeResponseCascade.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        newQuantity: Int?? = nil,
        platforms: [String: PlatformValue]? = nil,
        previousQuantity: Int?? = nil,
        productId: String?? = nil,
        soldOut: Bool? = nil
    ) -> DecrementAndCascadeResponseCascade {
        return DecrementAndCascadeResponseCascade(
            newQuantity: newQuantity ?? self.newQuantity,
            platforms: platforms ?? self.platforms,
            previousQuantity: previousQuantity ?? self.previousQuantity,
            productId: productId ?? self.productId,
            soldOut: soldOut ?? self.soldOut
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum PlatformValue: String, Codable, Sendable {
    case failed = "failed"
    case pendingManual = "pending-manual"
    case skipped = "skipped"
    case updated = "updated"
}

// MARK: - DetectMercariPullSyncDiffRequest
struct DetectMercariPullSyncDiffRequest: Codable, Sendable {
    let productId: String
    let scraped: DetectMercariPullSyncDiffRequestScraped

    enum CodingKeys: String, CodingKey {
        case productId = "productId"
        case scraped = "scraped"
    }
}

// MARK: DetectMercariPullSyncDiffRequest convenience initializers and mutators

extension DetectMercariPullSyncDiffRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DetectMercariPullSyncDiffRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        productId: String? = nil,
        scraped: DetectMercariPullSyncDiffRequestScraped? = nil
    ) -> DetectMercariPullSyncDiffRequest {
        return DetectMercariPullSyncDiffRequest(
            productId: productId ?? self.productId,
            scraped: scraped ?? self.scraped
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - DetectMercariPullSyncDiffRequestScraped
struct DetectMercariPullSyncDiffRequestScraped: Codable, Sendable {
    let description: String?
    let photoUrls: [String]?
    let price: Double?
    let status: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case description = "description"
        case photoUrls = "photoUrls"
        case price = "price"
        case status = "status"
        case title = "title"
    }
}

// MARK: DetectMercariPullSyncDiffRequestScraped convenience initializers and mutators

extension DetectMercariPullSyncDiffRequestScraped {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DetectMercariPullSyncDiffRequestScraped.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        photoUrls: [String]?? = nil,
        price: Double?? = nil,
        status: String?? = nil,
        title: String?? = nil
    ) -> DetectMercariPullSyncDiffRequestScraped {
        return DetectMercariPullSyncDiffRequestScraped(
            description: description ?? self.description,
            photoUrls: photoUrls ?? self.photoUrls,
            price: price ?? self.price,
            status: status ?? self.status,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - DetectMercariPullSyncDiffResponse
struct DetectMercariPullSyncDiffResponse: Codable, Sendable {
    let diffs: [DetectMercariPullSyncDiffResponseDiff]
    let inSync: Bool
    let productId: String

    enum CodingKeys: String, CodingKey {
        case diffs = "diffs"
        case inSync = "inSync"
        case productId = "productId"
    }
}

// MARK: DetectMercariPullSyncDiffResponse convenience initializers and mutators

extension DetectMercariPullSyncDiffResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DetectMercariPullSyncDiffResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        diffs: [DetectMercariPullSyncDiffResponseDiff]? = nil,
        inSync: Bool? = nil,
        productId: String? = nil
    ) -> DetectMercariPullSyncDiffResponse {
        return DetectMercariPullSyncDiffResponse(
            diffs: diffs ?? self.diffs,
            inSync: inSync ?? self.inSync,
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - DetectMercariPullSyncDiffResponseDiff
struct DetectMercariPullSyncDiffResponseDiff: Codable, Sendable {
    let field: Field
    let mercariValue: JSONAny?
    let productValue: JSONAny?

    enum CodingKeys: String, CodingKey {
        case field = "field"
        case mercariValue = "mercariValue"
        case productValue = "productValue"
    }
}

// MARK: DetectMercariPullSyncDiffResponseDiff convenience initializers and mutators

extension DetectMercariPullSyncDiffResponseDiff {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DetectMercariPullSyncDiffResponseDiff.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        field: Field? = nil,
        mercariValue: JSONAny?? = nil,
        productValue: JSONAny?? = nil
    ) -> DetectMercariPullSyncDiffResponseDiff {
        return DetectMercariPullSyncDiffResponseDiff(
            field: field ?? self.field,
            mercariValue: mercariValue ?? self.mercariValue,
            productValue: productValue ?? self.productValue
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum Field: String, Codable, Sendable {
    case description = "description"
    case photos = "photos"
    case price = "price"
    case status = "status"
    case title = "title"
}

// MARK: - EbayApplyDriftRequest
struct EbayApplyDriftRequest: Codable, Sendable {
    let fields: EbayApplyDriftRequestFields
    let productId: String

    enum CodingKeys: String, CodingKey {
        case fields = "fields"
        case productId = "productId"
    }
}

// MARK: EbayApplyDriftRequest convenience initializers and mutators

extension EbayApplyDriftRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayApplyDriftRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        fields: EbayApplyDriftRequestFields? = nil,
        productId: String? = nil
    ) -> EbayApplyDriftRequest {
        return EbayApplyDriftRequest(
            fields: fields ?? self.fields,
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayApplyDriftRequestFields
struct EbayApplyDriftRequestFields: Codable, Sendable {
    let price: Double?
    let quantity: Int?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case price = "price"
        case quantity = "quantity"
        case title = "title"
    }
}

// MARK: EbayApplyDriftRequestFields convenience initializers and mutators

extension EbayApplyDriftRequestFields {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayApplyDriftRequestFields.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        price: Double?? = nil,
        quantity: Int?? = nil,
        title: String?? = nil
    ) -> EbayApplyDriftRequestFields {
        return EbayApplyDriftRequestFields(
            price: price ?? self.price,
            quantity: quantity ?? self.quantity,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayApplyDriftResponse
struct EbayApplyDriftResponse: Codable, Sendable {
    let applied: [String]
    let ok: Bool

    enum CodingKeys: String, CodingKey {
        case applied = "applied"
        case ok = "ok"
    }
}

// MARK: EbayApplyDriftResponse convenience initializers and mutators

extension EbayApplyDriftResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayApplyDriftResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        applied: [String]? = nil,
        ok: Bool? = nil
    ) -> EbayApplyDriftResponse {
        return EbayApplyDriftResponse(
            applied: applied ?? self.applied,
            ok: ok ?? self.ok
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayCheckDriftRequest
struct EbayCheckDriftRequest: Codable, Sendable {
    let productId: String

    enum CodingKeys: String, CodingKey {
        case productId = "productId"
    }
}

// MARK: EbayCheckDriftRequest convenience initializers and mutators

extension EbayCheckDriftRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayCheckDriftRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        productId: String? = nil
    ) -> EbayCheckDriftRequest {
        return EbayCheckDriftRequest(
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayCheckDriftResponse
struct EbayCheckDriftResponse: Codable, Sendable {
    let diff: [EbayCheckDriftResponseDiff]
    let ebayData: EbayData
    let hasDrift: Bool
    let wonniData: EbayCheckDriftResponseWonniData

    enum CodingKeys: String, CodingKey {
        case diff = "diff"
        case ebayData = "ebayData"
        case hasDrift = "hasDrift"
        case wonniData = "wonniData"
    }
}

// MARK: EbayCheckDriftResponse convenience initializers and mutators

extension EbayCheckDriftResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayCheckDriftResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        diff: [EbayCheckDriftResponseDiff]? = nil,
        ebayData: EbayData? = nil,
        hasDrift: Bool? = nil,
        wonniData: EbayCheckDriftResponseWonniData? = nil
    ) -> EbayCheckDriftResponse {
        return EbayCheckDriftResponse(
            diff: diff ?? self.diff,
            ebayData: ebayData ?? self.ebayData,
            hasDrift: hasDrift ?? self.hasDrift,
            wonniData: wonniData ?? self.wonniData
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayCheckDriftResponseDiff
struct EbayCheckDriftResponseDiff: Codable, Sendable {
    let external: String
    let field: String
    let key: Key
    let value: Value
    let wonni: String

    enum CodingKeys: String, CodingKey {
        case external = "external"
        case field = "field"
        case key = "key"
        case value = "value"
        case wonni = "wonni"
    }
}

// MARK: EbayCheckDriftResponseDiff convenience initializers and mutators

extension EbayCheckDriftResponseDiff {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayCheckDriftResponseDiff.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        external: String? = nil,
        field: String? = nil,
        key: Key? = nil,
        value: Value? = nil,
        wonni: String? = nil
    ) -> EbayCheckDriftResponseDiff {
        return EbayCheckDriftResponseDiff(
            external: external ?? self.external,
            field: field ?? self.field,
            key: key ?? self.key,
            value: value ?? self.value,
            wonni: wonni ?? self.wonni
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum Key: String, Codable, Sendable {
    case price = "price"
    case quantity = "quantity"
    case title = "title"
}

enum Value: Codable, Sendable {
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(Double.self) {
            self = .double(x)
            return
        }
        if let x = try? container.decode(String.self) {
            self = .string(x)
            return
        }
        throw DecodingError.typeMismatch(Value.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for Value"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .double(let x):
            try container.encode(x)
        case .string(let x):
            try container.encode(x)
        }
    }
}

// MARK: - EbayData
struct EbayData: Codable, Sendable {
    let listingId: String?
    let price: Double?
    let quantity: Double?
    let status: String
    let title: String?

    enum CodingKeys: String, CodingKey {
        case listingId = "listingId"
        case price = "price"
        case quantity = "quantity"
        case status = "status"
        case title = "title"
    }
}

// MARK: EbayData convenience initializers and mutators

extension EbayData {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayData.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        listingId: String?? = nil,
        price: Double?? = nil,
        quantity: Double?? = nil,
        status: String? = nil,
        title: String?? = nil
    ) -> EbayData {
        return EbayData(
            listingId: listingId ?? self.listingId,
            price: price ?? self.price,
            quantity: quantity ?? self.quantity,
            status: status ?? self.status,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayCheckDriftResponseWonniData
struct EbayCheckDriftResponseWonniData: Codable, Sendable {
    let price: Double
    let quantity: Double
    let status: String
    let title: String

    enum CodingKeys: String, CodingKey {
        case price = "price"
        case quantity = "quantity"
        case status = "status"
        case title = "title"
    }
}

// MARK: EbayCheckDriftResponseWonniData convenience initializers and mutators

extension EbayCheckDriftResponseWonniData {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayCheckDriftResponseWonniData.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        price: Double? = nil,
        quantity: Double? = nil,
        status: String? = nil,
        title: String? = nil
    ) -> EbayCheckDriftResponseWonniData {
        return EbayCheckDriftResponseWonniData(
            price: price ?? self.price,
            quantity: quantity ?? self.quantity,
            status: status ?? self.status,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayCreateListingRequest
struct EbayCreateListingRequest: Codable, Sendable {
    let productId: String
    let skipAutofill: Bool?
    let titleOverride: String?

    enum CodingKeys: String, CodingKey {
        case productId = "productId"
        case skipAutofill = "skipAutofill"
        case titleOverride = "titleOverride"
    }
}

// MARK: EbayCreateListingRequest convenience initializers and mutators

extension EbayCreateListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayCreateListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        productId: String? = nil,
        skipAutofill: Bool?? = nil,
        titleOverride: String?? = nil
    ) -> EbayCreateListingRequest {
        return EbayCreateListingRequest(
            productId: productId ?? self.productId,
            skipAutofill: skipAutofill ?? self.skipAutofill,
            titleOverride: titleOverride ?? self.titleOverride
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayCreateListingResponse
struct EbayCreateListingResponse: Codable, Sendable {
    let inventoryItemGroupKey: String?
    let listingId: String
    let listingUrl: String
    let offerId: String?
    let variantOfferIds: [String: String]?

    enum CodingKeys: String, CodingKey {
        case inventoryItemGroupKey = "inventoryItemGroupKey"
        case listingId = "listingId"
        case listingUrl = "listingUrl"
        case offerId = "offerId"
        case variantOfferIds = "variantOfferIds"
    }
}

// MARK: EbayCreateListingResponse convenience initializers and mutators

extension EbayCreateListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayCreateListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        inventoryItemGroupKey: String?? = nil,
        listingId: String? = nil,
        listingUrl: String? = nil,
        offerId: String?? = nil,
        variantOfferIds: [String: String]?? = nil
    ) -> EbayCreateListingResponse {
        return EbayCreateListingResponse(
            inventoryItemGroupKey: inventoryItemGroupKey ?? self.inventoryItemGroupKey,
            listingId: listingId ?? self.listingId,
            listingUrl: listingUrl ?? self.listingUrl,
            offerId: offerId ?? self.offerId,
            variantOfferIds: variantOfferIds ?? self.variantOfferIds
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayDeleteListingRequest
struct EbayDeleteListingRequest: Codable, Sendable {
    let productId: String

    enum CodingKeys: String, CodingKey {
        case productId = "productId"
    }
}

// MARK: EbayDeleteListingRequest convenience initializers and mutators

extension EbayDeleteListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayDeleteListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        productId: String? = nil
    ) -> EbayDeleteListingRequest {
        return EbayDeleteListingRequest(
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayDeleteListingResponse
struct EbayDeleteListingResponse: Codable, Sendable {
    let ok: Bool

    enum CodingKeys: String, CodingKey {
        case ok = "ok"
    }
}

// MARK: EbayDeleteListingResponse convenience initializers and mutators

extension EbayDeleteListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayDeleteListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        ok: Bool? = nil
    ) -> EbayDeleteListingResponse {
        return EbayDeleteListingResponse(
            ok: ok ?? self.ok
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayGetListingRequest
struct EbayGetListingRequest: Codable, Sendable {
    let productId: String

    enum CodingKeys: String, CodingKey {
        case productId = "productId"
    }
}

// MARK: EbayGetListingRequest convenience initializers and mutators

extension EbayGetListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayGetListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        productId: String? = nil
    ) -> EbayGetListingRequest {
        return EbayGetListingRequest(
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayGetListingResponse
struct EbayGetListingResponse: Codable, Sendable {
    let group: Group?
    let listingId: String?
    let productId: String
    let status: String
    let totalSold: Int

    enum CodingKeys: String, CodingKey {
        case group = "group"
        case listingId = "listingId"
        case productId = "productId"
        case status = "status"
        case totalSold = "totalSold"
    }
}

// MARK: EbayGetListingResponse convenience initializers and mutators

extension EbayGetListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayGetListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        group: Group?? = nil,
        listingId: String?? = nil,
        productId: String? = nil,
        status: String? = nil,
        totalSold: Int? = nil
    ) -> EbayGetListingResponse {
        return EbayGetListingResponse(
            group: group ?? self.group,
            listingId: listingId ?? self.listingId,
            productId: productId ?? self.productId,
            status: status ?? self.status,
            totalSold: totalSold ?? self.totalSold
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Group
struct Group: Codable, Sendable {
    let title: String?
    let variantSkus: [String]?
    let variesBy: [String]?

    enum CodingKeys: String, CodingKey {
        case title = "title"
        case variantSkus = "variantSkus"
        case variesBy = "variesBy"
    }
}

// MARK: Group convenience initializers and mutators

extension Group {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Group.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        title: String?? = nil,
        variantSkus: [String]?? = nil,
        variesBy: [String]?? = nil
    ) -> Group {
        return Group(
            title: title ?? self.title,
            variantSkus: variantSkus ?? self.variantSkus,
            variesBy: variesBy ?? self.variesBy
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayImportListingRequest
struct EbayImportListingRequest: Codable, Sendable {
    let itemId: String

    enum CodingKeys: String, CodingKey {
        case itemId = "itemId"
    }
}

// MARK: EbayImportListingRequest convenience initializers and mutators

extension EbayImportListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayImportListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        itemId: String? = nil
    ) -> EbayImportListingRequest {
        return EbayImportListingRequest(
            itemId: itemId ?? self.itemId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayImportListingResponse
struct EbayImportListingResponse: Codable, Sendable {
    let condition: String
    let description: String
    let imageUrls: [String]
    let price: Double
    let title: String

    enum CodingKeys: String, CodingKey {
        case condition = "condition"
        case description = "description"
        case imageUrls = "imageUrls"
        case price = "price"
        case title = "title"
    }
}

// MARK: EbayImportListingResponse convenience initializers and mutators

extension EbayImportListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayImportListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        condition: String? = nil,
        description: String? = nil,
        imageUrls: [String]? = nil,
        price: Double? = nil,
        title: String? = nil
    ) -> EbayImportListingResponse {
        return EbayImportListingResponse(
            condition: condition ?? self.condition,
            description: description ?? self.description,
            imageUrls: imageUrls ?? self.imageUrls,
            price: price ?? self.price,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayUpdateListingRequest
struct EbayUpdateListingRequest: Codable, Sendable {
    let productId: String

    enum CodingKeys: String, CodingKey {
        case productId = "productId"
    }
}

// MARK: EbayUpdateListingRequest convenience initializers and mutators

extension EbayUpdateListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayUpdateListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        productId: String? = nil
    ) -> EbayUpdateListingRequest {
        return EbayUpdateListingRequest(
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EbayUpdateListingResponse
struct EbayUpdateListingResponse: Codable, Sendable {
    let listingId: String?
    let platform: EbayUpdateListingResponsePlatform
    let productId: String
    let status: EbayUpdateListingResponseStatus

    enum CodingKeys: String, CodingKey {
        case listingId = "listingId"
        case platform = "platform"
        case productId = "productId"
        case status = "status"
    }
}

// MARK: EbayUpdateListingResponse convenience initializers and mutators

extension EbayUpdateListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EbayUpdateListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        listingId: String?? = nil,
        platform: EbayUpdateListingResponsePlatform? = nil,
        productId: String? = nil,
        status: EbayUpdateListingResponseStatus? = nil
    ) -> EbayUpdateListingResponse {
        return EbayUpdateListingResponse(
            listingId: listingId ?? self.listingId,
            platform: platform ?? self.platform,
            productId: productId ?? self.productId,
            status: status ?? self.status
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum EbayUpdateListingResponsePlatform: String, Codable, Sendable {
    case ebay = "ebay"
    case etsy = "etsy"
    case mercari = "mercari"
    case tiktok = "tiktok"
    case wonni = "wonni"
}

enum EbayUpdateListingResponseStatus: String, Codable, Sendable {
    case active = "active"
    case error = "error"
    case inactive = "inactive"
    case none = "none"
    case sold = "sold"
}

// MARK: - EnrichListingRequest
struct EnrichListingRequest: Codable, Sendable {
    let hints: Hints?
    let images: [String]?
    let mode: Mode
    let fillBlanksOnly: Bool?
    let persist: Bool?
    let productId: String?

    enum CodingKeys: String, CodingKey {
        case hints = "hints"
        case images = "images"
        case mode = "mode"
        case fillBlanksOnly = "fillBlanksOnly"
        case persist = "persist"
        case productId = "productId"
    }
}

// MARK: EnrichListingRequest convenience initializers and mutators

extension EnrichListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EnrichListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        hints: Hints?? = nil,
        images: [String]?? = nil,
        mode: Mode? = nil,
        fillBlanksOnly: Bool?? = nil,
        persist: Bool?? = nil,
        productId: String?? = nil
    ) -> EnrichListingRequest {
        return EnrichListingRequest(
            hints: hints ?? self.hints,
            images: images ?? self.images,
            mode: mode ?? self.mode,
            fillBlanksOnly: fillBlanksOnly ?? self.fillBlanksOnly,
            persist: persist ?? self.persist,
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Hints
struct Hints: Codable, Sendable {
    let description: String?
    let price: Double?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case description = "description"
        case price = "price"
        case title = "title"
    }
}

// MARK: Hints convenience initializers and mutators

extension Hints {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Hints.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        price: Double?? = nil,
        title: String?? = nil
    ) -> Hints {
        return Hints(
            description: description ?? self.description,
            price: price ?? self.price,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum Mode: String, Codable, Sendable {
    case draft = "draft"
    case product = "product"
}

// MARK: - EnrichListingResponse
struct EnrichListingResponse: Codable, Sendable {
    let aiModel: String
    let aiPromptVersion: String
    let applied: [String]
    let proposals: Proposals
    let suggested: Suggested
    let writes: Writes

    enum CodingKeys: String, CodingKey {
        case aiModel = "aiModel"
        case aiPromptVersion = "aiPromptVersion"
        case applied = "applied"
        case proposals = "proposals"
        case suggested = "suggested"
        case writes = "writes"
    }
}

// MARK: EnrichListingResponse convenience initializers and mutators

extension EnrichListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EnrichListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        aiModel: String? = nil,
        aiPromptVersion: String? = nil,
        applied: [String]? = nil,
        proposals: Proposals? = nil,
        suggested: Suggested? = nil,
        writes: Writes? = nil
    ) -> EnrichListingResponse {
        return EnrichListingResponse(
            aiModel: aiModel ?? self.aiModel,
            aiPromptVersion: aiPromptVersion ?? self.aiPromptVersion,
            applied: applied ?? self.applied,
            proposals: proposals ?? self.proposals,
            suggested: suggested ?? self.suggested,
            writes: writes ?? self.writes
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Proposals
struct Proposals: Codable, Sendable {
    let description: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case description = "description"
        case title = "title"
    }
}

// MARK: Proposals convenience initializers and mutators

extension Proposals {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Proposals.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        title: String?? = nil
    ) -> Proposals {
        return Proposals(
            description: description ?? self.description,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Suggested
struct Suggested: Codable, Sendable {
    let brand: String?
    let category: String?
    let condition: Condition?
    let confidence: Double?
    let description: String?
    let heightIn: Double?
    let itemSpecifics: [String: String]?
    let lengthIn: Double?
    let shortTitle: String?
    let suggestedPrice: Double?
    let tags: [String]?
    let title: String?
    let weightOz: Double?
    let widthIn: Double?

    enum CodingKeys: String, CodingKey {
        case brand = "brand"
        case category = "category"
        case condition = "condition"
        case confidence = "confidence"
        case description = "description"
        case heightIn = "heightIn"
        case itemSpecifics = "itemSpecifics"
        case lengthIn = "lengthIn"
        case shortTitle = "shortTitle"
        case suggestedPrice = "suggestedPrice"
        case tags = "tags"
        case title = "title"
        case weightOz = "weightOz"
        case widthIn = "widthIn"
    }
}

// MARK: Suggested convenience initializers and mutators

extension Suggested {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Suggested.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        brand: String?? = nil,
        category: String?? = nil,
        condition: Condition?? = nil,
        confidence: Double?? = nil,
        description: String?? = nil,
        heightIn: Double?? = nil,
        itemSpecifics: [String: String]?? = nil,
        lengthIn: Double?? = nil,
        shortTitle: String?? = nil,
        suggestedPrice: Double?? = nil,
        tags: [String]?? = nil,
        title: String?? = nil,
        weightOz: Double?? = nil,
        widthIn: Double?? = nil
    ) -> Suggested {
        return Suggested(
            brand: brand ?? self.brand,
            category: category ?? self.category,
            condition: condition ?? self.condition,
            confidence: confidence ?? self.confidence,
            description: description ?? self.description,
            heightIn: heightIn ?? self.heightIn,
            itemSpecifics: itemSpecifics ?? self.itemSpecifics,
            lengthIn: lengthIn ?? self.lengthIn,
            shortTitle: shortTitle ?? self.shortTitle,
            suggestedPrice: suggestedPrice ?? self.suggestedPrice,
            tags: tags ?? self.tags,
            title: title ?? self.title,
            weightOz: weightOz ?? self.weightOz,
            widthIn: widthIn ?? self.widthIn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum Condition: String, Codable, Sendable {
    case fair = "fair"
    case good = "good"
    case likenew = "likenew"
    case new = "new"
    case poor = "poor"
}

// MARK: - Writes
struct Writes: Codable, Sendable {
    let brand: String?
    let category: String?
    let condition: Condition?
    let confidence: Double?
    let description: String?
    let heightIn: Double?
    let itemSpecifics: [String: String]?
    let lengthIn: Double?
    let shortTitle: String?
    let suggestedPrice: Double?
    let tags: [String]?
    let title: String?
    let weightOz: Double?
    let widthIn: Double?

    enum CodingKeys: String, CodingKey {
        case brand = "brand"
        case category = "category"
        case condition = "condition"
        case confidence = "confidence"
        case description = "description"
        case heightIn = "heightIn"
        case itemSpecifics = "itemSpecifics"
        case lengthIn = "lengthIn"
        case shortTitle = "shortTitle"
        case suggestedPrice = "suggestedPrice"
        case tags = "tags"
        case title = "title"
        case weightOz = "weightOz"
        case widthIn = "widthIn"
    }
}

// MARK: Writes convenience initializers and mutators

extension Writes {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Writes.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        brand: String?? = nil,
        category: String?? = nil,
        condition: Condition?? = nil,
        confidence: Double?? = nil,
        description: String?? = nil,
        heightIn: Double?? = nil,
        itemSpecifics: [String: String]?? = nil,
        lengthIn: Double?? = nil,
        shortTitle: String?? = nil,
        suggestedPrice: Double?? = nil,
        tags: [String]?? = nil,
        title: String?? = nil,
        weightOz: Double?? = nil,
        widthIn: Double?? = nil
    ) -> Writes {
        return Writes(
            brand: brand ?? self.brand,
            category: category ?? self.category,
            condition: condition ?? self.condition,
            confidence: confidence ?? self.confidence,
            description: description ?? self.description,
            heightIn: heightIn ?? self.heightIn,
            itemSpecifics: itemSpecifics ?? self.itemSpecifics,
            lengthIn: lengthIn ?? self.lengthIn,
            shortTitle: shortTitle ?? self.shortTitle,
            suggestedPrice: suggestedPrice ?? self.suggestedPrice,
            tags: tags ?? self.tags,
            title: title ?? self.title,
            weightOz: weightOz ?? self.weightOz,
            widthIn: widthIn ?? self.widthIn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyCheckShopSetupRequest
struct EtsyCheckShopSetupRequest: Codable, Sendable {
    let credentialSet: String?

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
    }
}

// MARK: EtsyCheckShopSetupRequest convenience initializers and mutators

extension EtsyCheckShopSetupRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyCheckShopSetupRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil
    ) -> EtsyCheckShopSetupRequest {
        return EtsyCheckShopSetupRequest(
            credentialSet: credentialSet ?? self.credentialSet
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyCheckShopSetupResponse
struct EtsyCheckShopSetupResponse: Codable, Sendable {
    let hasReturnPolicy: Bool
    let hasShippingProfile: Bool

    enum CodingKeys: String, CodingKey {
        case hasReturnPolicy = "hasReturnPolicy"
        case hasShippingProfile = "hasShippingProfile"
    }
}

// MARK: EtsyCheckShopSetupResponse convenience initializers and mutators

extension EtsyCheckShopSetupResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyCheckShopSetupResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        hasReturnPolicy: Bool? = nil,
        hasShippingProfile: Bool? = nil
    ) -> EtsyCheckShopSetupResponse {
        return EtsyCheckShopSetupResponse(
            hasReturnPolicy: hasReturnPolicy ?? self.hasReturnPolicy,
            hasShippingProfile: hasShippingProfile ?? self.hasShippingProfile
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyCreateListingRequest
struct EtsyCreateListingRequest: Codable, Sendable {
    let credentialSet: String?
    let productId: String
    let returnPolicyId: ReturnPolicyId?
    let shippingProfileId: ReturnPolicyId?
    let taxonomyId: ReturnPolicyId?

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
        case productId = "productId"
        case returnPolicyId = "returnPolicyId"
        case shippingProfileId = "shippingProfileId"
        case taxonomyId = "taxonomyId"
    }
}

// MARK: EtsyCreateListingRequest convenience initializers and mutators

extension EtsyCreateListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyCreateListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil,
        productId: String? = nil,
        returnPolicyId: ReturnPolicyId?? = nil,
        shippingProfileId: ReturnPolicyId?? = nil,
        taxonomyId: ReturnPolicyId?? = nil
    ) -> EtsyCreateListingRequest {
        return EtsyCreateListingRequest(
            credentialSet: credentialSet ?? self.credentialSet,
            productId: productId ?? self.productId,
            returnPolicyId: returnPolicyId ?? self.returnPolicyId,
            shippingProfileId: shippingProfileId ?? self.shippingProfileId,
            taxonomyId: taxonomyId ?? self.taxonomyId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum ReturnPolicyId: Codable, Sendable {
    case double(Double)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(Double.self) {
            self = .double(x)
            return
        }
        if let x = try? container.decode(String.self) {
            self = .string(x)
            return
        }
        if container.decodeNil() {
            self = .null
            return
        }
        throw DecodingError.typeMismatch(ReturnPolicyId.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for ReturnPolicyId"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .double(let x):
            try container.encode(x)
        case .string(let x):
            try container.encode(x)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - EtsyCreateListingResponse
struct EtsyCreateListingResponse: Codable, Sendable {
    let listingId: String
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case listingId = "listingId"
        case success = "success"
    }
}

// MARK: EtsyCreateListingResponse convenience initializers and mutators

extension EtsyCreateListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyCreateListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        listingId: String? = nil,
        success: Bool? = nil
    ) -> EtsyCreateListingResponse {
        return EtsyCreateListingResponse(
            listingId: listingId ?? self.listingId,
            success: success ?? self.success
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyDeleteListingRequest
struct EtsyDeleteListingRequest: Codable, Sendable {
    let credentialSet: String?
    let productId: String

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
        case productId = "productId"
    }
}

// MARK: EtsyDeleteListingRequest convenience initializers and mutators

extension EtsyDeleteListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyDeleteListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil,
        productId: String? = nil
    ) -> EtsyDeleteListingRequest {
        return EtsyDeleteListingRequest(
            credentialSet: credentialSet ?? self.credentialSet,
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyDeleteListingResponse
struct EtsyDeleteListingResponse: Codable, Sendable {
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case success = "success"
    }
}

// MARK: EtsyDeleteListingResponse convenience initializers and mutators

extension EtsyDeleteListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyDeleteListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        success: Bool? = nil
    ) -> EtsyDeleteListingResponse {
        return EtsyDeleteListingResponse(
            success: success ?? self.success
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyImportPullSyncRequest
struct EtsyImportPullSyncRequest: Codable, Sendable {
    let credentialSet: String?
    let fields: EtsyImportPullSyncRequestFields
    let productId: String

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
        case fields = "fields"
        case productId = "productId"
    }
}

// MARK: EtsyImportPullSyncRequest convenience initializers and mutators

extension EtsyImportPullSyncRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyImportPullSyncRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil,
        fields: EtsyImportPullSyncRequestFields? = nil,
        productId: String? = nil
    ) -> EtsyImportPullSyncRequest {
        return EtsyImportPullSyncRequest(
            credentialSet: credentialSet ?? self.credentialSet,
            fields: fields ?? self.fields,
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyImportPullSyncRequestFields
struct EtsyImportPullSyncRequestFields: Codable, Sendable {
    let price: Double?
    let quantity: Int?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case price = "price"
        case quantity = "quantity"
        case title = "title"
    }
}

// MARK: EtsyImportPullSyncRequestFields convenience initializers and mutators

extension EtsyImportPullSyncRequestFields {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyImportPullSyncRequestFields.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        price: Double?? = nil,
        quantity: Int?? = nil,
        title: String?? = nil
    ) -> EtsyImportPullSyncRequestFields {
        return EtsyImportPullSyncRequestFields(
            price: price ?? self.price,
            quantity: quantity ?? self.quantity,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyImportPullSyncResponse
struct EtsyImportPullSyncResponse: Codable, Sendable {
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case success = "success"
    }
}

// MARK: EtsyImportPullSyncResponse convenience initializers and mutators

extension EtsyImportPullSyncResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyImportPullSyncResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        success: Bool? = nil
    ) -> EtsyImportPullSyncResponse {
        return EtsyImportPullSyncResponse(
            success: success ?? self.success
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyPullSyncRequest
struct EtsyPullSyncRequest: Codable, Sendable {
    let credentialSet: String?
    let productId: String

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
        case productId = "productId"
    }
}

// MARK: EtsyPullSyncRequest convenience initializers and mutators

extension EtsyPullSyncRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyPullSyncRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil,
        productId: String? = nil
    ) -> EtsyPullSyncRequest {
        return EtsyPullSyncRequest(
            credentialSet: credentialSet ?? self.credentialSet,
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyPullSyncResponse
struct EtsyPullSyncResponse: Codable, Sendable {
    let diff: [EtsyPullSyncResponseDiff]
    let etsyData: EtsyData
    let hasDrift: Bool
    let wonniData: EtsyPullSyncResponseWonniData

    enum CodingKeys: String, CodingKey {
        case diff = "diff"
        case etsyData = "etsyData"
        case hasDrift = "hasDrift"
        case wonniData = "wonniData"
    }
}

// MARK: EtsyPullSyncResponse convenience initializers and mutators

extension EtsyPullSyncResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyPullSyncResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        diff: [EtsyPullSyncResponseDiff]? = nil,
        etsyData: EtsyData? = nil,
        hasDrift: Bool? = nil,
        wonniData: EtsyPullSyncResponseWonniData? = nil
    ) -> EtsyPullSyncResponse {
        return EtsyPullSyncResponse(
            diff: diff ?? self.diff,
            etsyData: etsyData ?? self.etsyData,
            hasDrift: hasDrift ?? self.hasDrift,
            wonniData: wonniData ?? self.wonniData
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyPullSyncResponseDiff
struct EtsyPullSyncResponseDiff: Codable, Sendable {
    let external: String
    let field: String
    let key: Key
    let value: Value
    let wonni: String

    enum CodingKeys: String, CodingKey {
        case external = "external"
        case field = "field"
        case key = "key"
        case value = "value"
        case wonni = "wonni"
    }
}

// MARK: EtsyPullSyncResponseDiff convenience initializers and mutators

extension EtsyPullSyncResponseDiff {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyPullSyncResponseDiff.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        external: String? = nil,
        field: String? = nil,
        key: Key? = nil,
        value: Value? = nil,
        wonni: String? = nil
    ) -> EtsyPullSyncResponseDiff {
        return EtsyPullSyncResponseDiff(
            external: external ?? self.external,
            field: field ?? self.field,
            key: key ?? self.key,
            value: value ?? self.value,
            wonni: wonni ?? self.wonni
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyData
struct EtsyData: Codable, Sendable {
    let listingId: String
    let price: Double?
    let quantity: Double?
    let status: String
    let title: String?

    enum CodingKeys: String, CodingKey {
        case listingId = "listingId"
        case price = "price"
        case quantity = "quantity"
        case status = "status"
        case title = "title"
    }
}

// MARK: EtsyData convenience initializers and mutators

extension EtsyData {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyData.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        listingId: String? = nil,
        price: Double?? = nil,
        quantity: Double?? = nil,
        status: String? = nil,
        title: String?? = nil
    ) -> EtsyData {
        return EtsyData(
            listingId: listingId ?? self.listingId,
            price: price ?? self.price,
            quantity: quantity ?? self.quantity,
            status: status ?? self.status,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyPullSyncResponseWonniData
struct EtsyPullSyncResponseWonniData: Codable, Sendable {
    let price: Double
    let quantity: Double
    let status: String
    let title: String

    enum CodingKeys: String, CodingKey {
        case price = "price"
        case quantity = "quantity"
        case status = "status"
        case title = "title"
    }
}

// MARK: EtsyPullSyncResponseWonniData convenience initializers and mutators

extension EtsyPullSyncResponseWonniData {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyPullSyncResponseWonniData.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        price: Double? = nil,
        quantity: Double? = nil,
        status: String? = nil,
        title: String? = nil
    ) -> EtsyPullSyncResponseWonniData {
        return EtsyPullSyncResponseWonniData(
            price: price ?? self.price,
            quantity: quantity ?? self.quantity,
            status: status ?? self.status,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyUpdateListingRequest
struct EtsyUpdateListingRequest: Codable, Sendable {
    let credentialSet: String?
    let productId: String

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
        case productId = "productId"
    }
}

// MARK: EtsyUpdateListingRequest convenience initializers and mutators

extension EtsyUpdateListingRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyUpdateListingRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil,
        productId: String? = nil
    ) -> EtsyUpdateListingRequest {
        return EtsyUpdateListingRequest(
            credentialSet: credentialSet ?? self.credentialSet,
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - EtsyUpdateListingResponse
struct EtsyUpdateListingResponse: Codable, Sendable {
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case success = "success"
    }
}

// MARK: EtsyUpdateListingResponse convenience initializers and mutators

extension EtsyUpdateListingResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(EtsyUpdateListingResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        success: Bool? = nil
    ) -> EtsyUpdateListingResponse {
        return EtsyUpdateListingResponse(
            success: success ?? self.success
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - GetEtsyCategoriesRequest
struct GetEtsyCategoriesRequest: Codable, Sendable {
    let credentialSet: String?

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
    }
}

// MARK: GetEtsyCategoriesRequest convenience initializers and mutators

extension GetEtsyCategoriesRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetEtsyCategoriesRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil
    ) -> GetEtsyCategoriesRequest {
        return GetEtsyCategoriesRequest(
            credentialSet: credentialSet ?? self.credentialSet
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - GetEtsyCategoriesResponse
struct GetEtsyCategoriesResponse: Codable, Sendable {
    let categories: [Category]

    enum CodingKeys: String, CodingKey {
        case categories = "categories"
    }
}

// MARK: GetEtsyCategoriesResponse convenience initializers and mutators

extension GetEtsyCategoriesResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetEtsyCategoriesResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        categories: [Category]? = nil
    ) -> GetEtsyCategoriesResponse {
        return GetEtsyCategoriesResponse(
            categories: categories ?? self.categories
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Category
struct Category: Codable, Sendable {
    let id: Double
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case name = "name"
    }
}

// MARK: Category convenience initializers and mutators

extension Category {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Category.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        id: Double? = nil,
        name: String? = nil
    ) -> Category {
        return Category(
            id: id ?? self.id,
            name: name ?? self.name
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - GetEtsyReturnPoliciesRequest
struct GetEtsyReturnPoliciesRequest: Codable, Sendable {
    let credentialSet: String?

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
    }
}

// MARK: GetEtsyReturnPoliciesRequest convenience initializers and mutators

extension GetEtsyReturnPoliciesRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetEtsyReturnPoliciesRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil
    ) -> GetEtsyReturnPoliciesRequest {
        return GetEtsyReturnPoliciesRequest(
            credentialSet: credentialSet ?? self.credentialSet
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - GetEtsyReturnPoliciesResponse
struct GetEtsyReturnPoliciesResponse: Codable, Sendable {
    let policies: [Policy]

    enum CodingKeys: String, CodingKey {
        case policies = "policies"
    }
}

// MARK: GetEtsyReturnPoliciesResponse convenience initializers and mutators

extension GetEtsyReturnPoliciesResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetEtsyReturnPoliciesResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        policies: [Policy]? = nil
    ) -> GetEtsyReturnPoliciesResponse {
        return GetEtsyReturnPoliciesResponse(
            policies: policies ?? self.policies
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Policy
struct Policy: Codable, Sendable {
    let id: Value
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case name = "name"
    }
}

// MARK: Policy convenience initializers and mutators

extension Policy {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Policy.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        id: Value? = nil,
        name: String? = nil
    ) -> Policy {
        return Policy(
            id: id ?? self.id,
            name: name ?? self.name
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - GetEtsyShippingProfilesRequest
struct GetEtsyShippingProfilesRequest: Codable, Sendable {
    let credentialSet: String?

    enum CodingKeys: String, CodingKey {
        case credentialSet = "credentialSet"
    }
}

// MARK: GetEtsyShippingProfilesRequest convenience initializers and mutators

extension GetEtsyShippingProfilesRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetEtsyShippingProfilesRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        credentialSet: String?? = nil
    ) -> GetEtsyShippingProfilesRequest {
        return GetEtsyShippingProfilesRequest(
            credentialSet: credentialSet ?? self.credentialSet
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - GetEtsyShippingProfilesResponse
struct GetEtsyShippingProfilesResponse: Codable, Sendable {
    let profiles: [Profile]

    enum CodingKeys: String, CodingKey {
        case profiles = "profiles"
    }
}

// MARK: GetEtsyShippingProfilesResponse convenience initializers and mutators

extension GetEtsyShippingProfilesResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetEtsyShippingProfilesResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        profiles: [Profile]? = nil
    ) -> GetEtsyShippingProfilesResponse {
        return GetEtsyShippingProfilesResponse(
            profiles: profiles ?? self.profiles
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Profile
struct Profile: Codable, Sendable {
    let id: Value
    let title: String

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case title = "title"
    }
}

// MARK: Profile convenience initializers and mutators

extension Profile {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Profile.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        id: Value? = nil,
        title: String? = nil
    ) -> Profile {
        return Profile(
            id: id ?? self.id,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - GetOrderTakeHomeRequest
struct GetOrderTakeHomeRequest: Codable, Sendable {
    let saleId: String

    enum CodingKeys: String, CodingKey {
        case saleId = "saleId"
    }
}

// MARK: GetOrderTakeHomeRequest convenience initializers and mutators

extension GetOrderTakeHomeRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetOrderTakeHomeRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        saleId: String? = nil
    ) -> GetOrderTakeHomeRequest {
        return GetOrderTakeHomeRequest(
            saleId: saleId ?? self.saleId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - GetOrderTakeHomeResponse
struct GetOrderTakeHomeResponse: Codable, Sendable {
    let fees: Double?
    let provisional: Bool
    let shippingLabelCost: Double?
    let takeHome: Double?

    enum CodingKeys: String, CodingKey {
        case fees = "fees"
        case provisional = "provisional"
        case shippingLabelCost = "shippingLabelCost"
        case takeHome = "takeHome"
    }
}

// MARK: GetOrderTakeHomeResponse convenience initializers and mutators

extension GetOrderTakeHomeResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(GetOrderTakeHomeResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        fees: Double?? = nil,
        provisional: Bool? = nil,
        shippingLabelCost: Double?? = nil,
        takeHome: Double?? = nil
    ) -> GetOrderTakeHomeResponse {
        return GetOrderTakeHomeResponse(
            fees: fees ?? self.fees,
            provisional: provisional ?? self.provisional,
            shippingLabelCost: shippingLabelCost ?? self.shippingLabelCost,
            takeHome: takeHome ?? self.takeHome
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ImportMercariPullSyncRequest
struct ImportMercariPullSyncRequest: Codable, Sendable {
    let fields: [Field]
    let productId: String
    let scraped: ImportMercariPullSyncRequestScraped

    enum CodingKeys: String, CodingKey {
        case fields = "fields"
        case productId = "productId"
        case scraped = "scraped"
    }
}

// MARK: ImportMercariPullSyncRequest convenience initializers and mutators

extension ImportMercariPullSyncRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ImportMercariPullSyncRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        fields: [Field]? = nil,
        productId: String? = nil,
        scraped: ImportMercariPullSyncRequestScraped? = nil
    ) -> ImportMercariPullSyncRequest {
        return ImportMercariPullSyncRequest(
            fields: fields ?? self.fields,
            productId: productId ?? self.productId,
            scraped: scraped ?? self.scraped
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ImportMercariPullSyncRequestScraped
struct ImportMercariPullSyncRequestScraped: Codable, Sendable {
    let description: String?
    let photoUrls: [String]?
    let price: Double?
    let status: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case description = "description"
        case photoUrls = "photoUrls"
        case price = "price"
        case status = "status"
        case title = "title"
    }
}

// MARK: ImportMercariPullSyncRequestScraped convenience initializers and mutators

extension ImportMercariPullSyncRequestScraped {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ImportMercariPullSyncRequestScraped.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        photoUrls: [String]?? = nil,
        price: Double?? = nil,
        status: String?? = nil,
        title: String?? = nil
    ) -> ImportMercariPullSyncRequestScraped {
        return ImportMercariPullSyncRequestScraped(
            description: description ?? self.description,
            photoUrls: photoUrls ?? self.photoUrls,
            price: price ?? self.price,
            status: status ?? self.status,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ImportMercariPullSyncResponse
struct ImportMercariPullSyncResponse: Codable, Sendable {
    let ok: Bool
    let updated: [String]

    enum CodingKeys: String, CodingKey {
        case ok = "ok"
        case updated = "updated"
    }
}

// MARK: ImportMercariPullSyncResponse convenience initializers and mutators

extension ImportMercariPullSyncResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ImportMercariPullSyncResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        ok: Bool? = nil,
        updated: [String]? = nil
    ) -> ImportMercariPullSyncResponse {
        return ImportMercariPullSyncResponse(
            ok: ok ?? self.ok,
            updated: updated ?? self.updated
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ListingFields
struct ListingFields: Codable, Sendable {
    let brand: String?
    let category: String?
    let condition: Condition?
    let confidence: Double?
    let description: String?
    let heightIn: Double?
    let itemSpecifics: [String: String]?
    let lengthIn: Double?
    let shortTitle: String?
    let suggestedPrice: Double?
    let tags: [String]?
    let title: String?
    let weightOz: Double?
    let widthIn: Double?

    enum CodingKeys: String, CodingKey {
        case brand = "brand"
        case category = "category"
        case condition = "condition"
        case confidence = "confidence"
        case description = "description"
        case heightIn = "heightIn"
        case itemSpecifics = "itemSpecifics"
        case lengthIn = "lengthIn"
        case shortTitle = "shortTitle"
        case suggestedPrice = "suggestedPrice"
        case tags = "tags"
        case title = "title"
        case weightOz = "weightOz"
        case widthIn = "widthIn"
    }
}

// MARK: ListingFields convenience initializers and mutators

extension ListingFields {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ListingFields.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        brand: String?? = nil,
        category: String?? = nil,
        condition: Condition?? = nil,
        confidence: Double?? = nil,
        description: String?? = nil,
        heightIn: Double?? = nil,
        itemSpecifics: [String: String]?? = nil,
        lengthIn: Double?? = nil,
        shortTitle: String?? = nil,
        suggestedPrice: Double?? = nil,
        tags: [String]?? = nil,
        title: String?? = nil,
        weightOz: Double?? = nil,
        widthIn: Double?? = nil
    ) -> ListingFields {
        return ListingFields(
            brand: brand ?? self.brand,
            category: category ?? self.category,
            condition: condition ?? self.condition,
            confidence: confidence ?? self.confidence,
            description: description ?? self.description,
            heightIn: heightIn ?? self.heightIn,
            itemSpecifics: itemSpecifics ?? self.itemSpecifics,
            lengthIn: lengthIn ?? self.lengthIn,
            shortTitle: shortTitle ?? self.shortTitle,
            suggestedPrice: suggestedPrice ?? self.suggestedPrice,
            tags: tags ?? self.tags,
            title: title ?? self.title,
            weightOz: weightOz ?? self.weightOz,
            widthIn: widthIn ?? self.widthIn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - MarkSoldOutAndCascadeRequest
struct MarkSoldOutAndCascadeRequest: Codable, Sendable {
    let productId: String

    enum CodingKeys: String, CodingKey {
        case productId = "productId"
    }
}

// MARK: MarkSoldOutAndCascadeRequest convenience initializers and mutators

extension MarkSoldOutAndCascadeRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MarkSoldOutAndCascadeRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        productId: String? = nil
    ) -> MarkSoldOutAndCascadeRequest {
        return MarkSoldOutAndCascadeRequest(
            productId: productId ?? self.productId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - MarkSoldOutAndCascadeResponse
struct MarkSoldOutAndCascadeResponse: Codable, Sendable {
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case success = "success"
    }
}

// MARK: MarkSoldOutAndCascadeResponse convenience initializers and mutators

extension MarkSoldOutAndCascadeResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MarkSoldOutAndCascadeResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        success: Bool? = nil
    ) -> MarkSoldOutAndCascadeResponse {
        return MarkSoldOutAndCascadeResponse(
            success: success ?? self.success
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - MercariScrapeItem
struct MercariScrapeItem: Codable, Sendable {
    let buyerName: String?
    let mercariItemId: String
    let mercariOrderId: String?
    let priceSoldFor: Double
    let shippingRevenue: Double?
    let soldAt: SoldAtUnion?
    let soldDate: String?
    let soldDateText: String?
    let takeHome: Double?
    let thumbnailUrl: String?
    let title: String?
    let trackingNumber: String?

    enum CodingKeys: String, CodingKey {
        case buyerName = "buyerName"
        case mercariItemId = "mercariItemId"
        case mercariOrderId = "mercariOrderId"
        case priceSoldFor = "priceSoldFor"
        case shippingRevenue = "shippingRevenue"
        case soldAt = "soldAt"
        case soldDate = "soldDate"
        case soldDateText = "soldDateText"
        case takeHome = "takeHome"
        case thumbnailUrl = "thumbnailUrl"
        case title = "title"
        case trackingNumber = "trackingNumber"
    }
}

// MARK: MercariScrapeItem convenience initializers and mutators

extension MercariScrapeItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MercariScrapeItem.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        buyerName: String?? = nil,
        mercariItemId: String? = nil,
        mercariOrderId: String?? = nil,
        priceSoldFor: Double? = nil,
        shippingRevenue: Double?? = nil,
        soldAt: SoldAtUnion?? = nil,
        soldDate: String?? = nil,
        soldDateText: String?? = nil,
        takeHome: Double?? = nil,
        thumbnailUrl: String?? = nil,
        title: String?? = nil,
        trackingNumber: String?? = nil
    ) -> MercariScrapeItem {
        return MercariScrapeItem(
            buyerName: buyerName ?? self.buyerName,
            mercariItemId: mercariItemId ?? self.mercariItemId,
            mercariOrderId: mercariOrderId ?? self.mercariOrderId,
            priceSoldFor: priceSoldFor ?? self.priceSoldFor,
            shippingRevenue: shippingRevenue ?? self.shippingRevenue,
            soldAt: soldAt ?? self.soldAt,
            soldDate: soldDate ?? self.soldDate,
            soldDateText: soldDateText ?? self.soldDateText,
            takeHome: takeHome ?? self.takeHome,
            thumbnailUrl: thumbnailUrl ?? self.thumbnailUrl,
            title: title ?? self.title,
            trackingNumber: trackingNumber ?? self.trackingNumber
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum SoldAtUnion: Codable, Sendable {
    case dateTime(Date)
    case integer(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(Int.self) {
            self = .integer(x)
            return
        }
        if let x = try? container.decode(Date.self) {
            self = .dateTime(x)
            return
        }
        if container.decodeNil() {
            self = .null
            return
        }
        throw DecodingError.typeMismatch(SoldAtUnion.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for SoldAtUnion"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .dateTime(let x):
            try container.encode(x)
        case .integer(let x):
            try container.encode(x)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - RecordMercariSalesBatchRequest
struct RecordMercariSalesBatchRequest: Codable, Sendable {
    let items: [Item]?
    let rawItems: [RawItem]?

    enum CodingKeys: String, CodingKey {
        case items = "items"
        case rawItems = "rawItems"
    }
}

// MARK: RecordMercariSalesBatchRequest convenience initializers and mutators

extension RecordMercariSalesBatchRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RecordMercariSalesBatchRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        items: [Item]?? = nil,
        rawItems: [RawItem]?? = nil
    ) -> RecordMercariSalesBatchRequest {
        return RecordMercariSalesBatchRequest(
            items: items ?? self.items,
            rawItems: rawItems ?? self.rawItems
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Item
struct Item: Codable, Sendable {
    let mercariItemId: String

    enum CodingKeys: String, CodingKey {
        case mercariItemId = "mercariItemId"
    }
}

// MARK: Item convenience initializers and mutators

extension Item {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Item.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        mercariItemId: String? = nil
    ) -> Item {
        return Item(
            mercariItemId: mercariItemId ?? self.mercariItemId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - RawItem
struct RawItem: Codable, Sendable {
    let mercariItemId: String

    enum CodingKeys: String, CodingKey {
        case mercariItemId = "mercariItemId"
    }
}

// MARK: RawItem convenience initializers and mutators

extension RawItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RawItem.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        mercariItemId: String? = nil
    ) -> RawItem {
        return RawItem(
            mercariItemId: mercariItemId ?? self.mercariItemId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - RecordMercariSalesBatchResponse
struct RecordMercariSalesBatchResponse: Codable, Sendable {
    let duplicates: Int
    let recorded: Int
    let results: [Result]
    let unmatched: Int

    enum CodingKeys: String, CodingKey {
        case duplicates = "duplicates"
        case recorded = "recorded"
        case results = "results"
        case unmatched = "unmatched"
    }
}

// MARK: RecordMercariSalesBatchResponse convenience initializers and mutators

extension RecordMercariSalesBatchResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RecordMercariSalesBatchResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        duplicates: Int? = nil,
        recorded: Int? = nil,
        results: [Result]? = nil,
        unmatched: Int? = nil
    ) -> RecordMercariSalesBatchResponse {
        return RecordMercariSalesBatchResponse(
            duplicates: duplicates ?? self.duplicates,
            recorded: recorded ?? self.recorded,
            results: results ?? self.results,
            unmatched: unmatched ?? self.unmatched
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Result
struct Result: Codable, Sendable {
    let mercariItemId: String
    let outcome: Outcome
    let productId: String?
    let saleId: String?
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case mercariItemId = "mercariItemId"
        case outcome = "outcome"
        case productId = "productId"
        case saleId = "saleId"
        case warning = "warning"
    }
}

// MARK: Result convenience initializers and mutators

extension Result {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Result.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        mercariItemId: String? = nil,
        outcome: Outcome? = nil,
        productId: String?? = nil,
        saleId: String?? = nil,
        warning: String?? = nil
    ) -> Result {
        return Result(
            mercariItemId: mercariItemId ?? self.mercariItemId,
            outcome: outcome ?? self.outcome,
            productId: productId ?? self.productId,
            saleId: saleId ?? self.saleId,
            warning: warning ?? self.warning
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum Outcome: String, Codable, Sendable {
    case duplicate = "duplicate"
    case noMatch = "no-match"
    case parseFailed = "parse-failed"
    case recorded = "recorded"
}

// MARK: - RecordSaleRequest
struct RecordSaleRequest: Codable, Sendable {
    let buyerAddress: RecordSaleRequestBuyerAddress?
    let buyerName: String?
    let carrier: Carrier?
    let cascade: Bool?
    let externalUrl: String?
    let listingTitle: String?
    let notes: String?
    let platform: DecrementAndCascadeRequestPlatform
    let platformItemId: String?
    let platformOrderId: String?
    let productId: String?
    let quantity: Int?
    let shippingLabelCost: Double?
    let shippingRevenue: Double?
    let soldAt: SoldAtUnion?
    let soldPrice: Double
    let takeHome: Double?
    let trackingNumber: String?
    let variantSku: String?

    enum CodingKeys: String, CodingKey {
        case buyerAddress = "buyerAddress"
        case buyerName = "buyerName"
        case carrier = "carrier"
        case cascade = "cascade"
        case externalUrl = "externalUrl"
        case listingTitle = "listingTitle"
        case notes = "notes"
        case platform = "platform"
        case platformItemId = "platformItemId"
        case platformOrderId = "platformOrderId"
        case productId = "productId"
        case quantity = "quantity"
        case shippingLabelCost = "shippingLabelCost"
        case shippingRevenue = "shippingRevenue"
        case soldAt = "soldAt"
        case soldPrice = "soldPrice"
        case takeHome = "takeHome"
        case trackingNumber = "trackingNumber"
        case variantSku = "variantSku"
    }
}

// MARK: RecordSaleRequest convenience initializers and mutators

extension RecordSaleRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RecordSaleRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        buyerAddress: RecordSaleRequestBuyerAddress?? = nil,
        buyerName: String?? = nil,
        carrier: Carrier?? = nil,
        cascade: Bool?? = nil,
        externalUrl: String?? = nil,
        listingTitle: String?? = nil,
        notes: String?? = nil,
        platform: DecrementAndCascadeRequestPlatform? = nil,
        platformItemId: String?? = nil,
        platformOrderId: String?? = nil,
        productId: String?? = nil,
        quantity: Int?? = nil,
        shippingLabelCost: Double?? = nil,
        shippingRevenue: Double?? = nil,
        soldAt: SoldAtUnion?? = nil,
        soldPrice: Double? = nil,
        takeHome: Double?? = nil,
        trackingNumber: String?? = nil,
        variantSku: String?? = nil
    ) -> RecordSaleRequest {
        return RecordSaleRequest(
            buyerAddress: buyerAddress ?? self.buyerAddress,
            buyerName: buyerName ?? self.buyerName,
            carrier: carrier ?? self.carrier,
            cascade: cascade ?? self.cascade,
            externalUrl: externalUrl ?? self.externalUrl,
            listingTitle: listingTitle ?? self.listingTitle,
            notes: notes ?? self.notes,
            platform: platform ?? self.platform,
            platformItemId: platformItemId ?? self.platformItemId,
            platformOrderId: platformOrderId ?? self.platformOrderId,
            productId: productId ?? self.productId,
            quantity: quantity ?? self.quantity,
            shippingLabelCost: shippingLabelCost ?? self.shippingLabelCost,
            shippingRevenue: shippingRevenue ?? self.shippingRevenue,
            soldAt: soldAt ?? self.soldAt,
            soldPrice: soldPrice ?? self.soldPrice,
            takeHome: takeHome ?? self.takeHome,
            trackingNumber: trackingNumber ?? self.trackingNumber,
            variantSku: variantSku ?? self.variantSku
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - RecordSaleRequestBuyerAddress
struct RecordSaleRequestBuyerAddress: Codable, Sendable {
    let city: String?
    let country: String?
    let line1: String?
    let line2: String?
    let name: String?
    let state: String?
    let zip: String?

    enum CodingKeys: String, CodingKey {
        case city = "city"
        case country = "country"
        case line1 = "line1"
        case line2 = "line2"
        case name = "name"
        case state = "state"
        case zip = "zip"
    }
}

// MARK: RecordSaleRequestBuyerAddress convenience initializers and mutators

extension RecordSaleRequestBuyerAddress {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RecordSaleRequestBuyerAddress.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        city: String?? = nil,
        country: String?? = nil,
        line1: String?? = nil,
        line2: String?? = nil,
        name: String?? = nil,
        state: String?? = nil,
        zip: String?? = nil
    ) -> RecordSaleRequestBuyerAddress {
        return RecordSaleRequestBuyerAddress(
            city: city ?? self.city,
            country: country ?? self.country,
            line1: line1 ?? self.line1,
            line2: line2 ?? self.line2,
            name: name ?? self.name,
            state: state ?? self.state,
            zip: zip ?? self.zip
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum Carrier: String, Codable, Sendable {
    case dhl = "DHL"
    case fedEx = "FedEx"
    case other = "other"
    case ups = "UPS"
    case usps = "USPS"
}

// MARK: - RecordSaleResponse
struct RecordSaleResponse: Codable, Sendable {
    let cascade: RecordSaleResponseCascade?
    let created: Bool
    let saleId: String

    enum CodingKeys: String, CodingKey {
        case cascade = "cascade"
        case created = "created"
        case saleId = "saleId"
    }
}

// MARK: RecordSaleResponse convenience initializers and mutators

extension RecordSaleResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RecordSaleResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        cascade: RecordSaleResponseCascade?? = nil,
        created: Bool? = nil,
        saleId: String? = nil
    ) -> RecordSaleResponse {
        return RecordSaleResponse(
            cascade: cascade ?? self.cascade,
            created: created ?? self.created,
            saleId: saleId ?? self.saleId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - RecordSaleResponseCascade
struct RecordSaleResponseCascade: Codable, Sendable {
    let newQuantity: Int?
    let platforms: [String: PlatformValue]
    let previousQuantity: Int?
    let productId: String?
    let soldOut: Bool

    enum CodingKeys: String, CodingKey {
        case newQuantity = "newQuantity"
        case platforms = "platforms"
        case previousQuantity = "previousQuantity"
        case productId = "productId"
        case soldOut = "soldOut"
    }
}

// MARK: RecordSaleResponseCascade convenience initializers and mutators

extension RecordSaleResponseCascade {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RecordSaleResponseCascade.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        newQuantity: Int?? = nil,
        platforms: [String: PlatformValue]? = nil,
        previousQuantity: Int?? = nil,
        productId: String?? = nil,
        soldOut: Bool? = nil
    ) -> RecordSaleResponseCascade {
        return RecordSaleResponseCascade(
            newQuantity: newQuantity ?? self.newQuantity,
            platforms: platforms ?? self.platforms,
            previousQuantity: previousQuantity ?? self.previousQuantity,
            productId: productId ?? self.productId,
            soldOut: soldOut ?? self.soldOut
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - RestockAndCascadeRequest
struct RestockAndCascadeRequest: Codable, Sendable {
    let productId: String
    let quantity: Int
    let variantSku: String?

    enum CodingKeys: String, CodingKey {
        case productId = "productId"
        case quantity = "quantity"
        case variantSku = "variantSku"
    }
}

// MARK: RestockAndCascadeRequest convenience initializers and mutators

extension RestockAndCascadeRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RestockAndCascadeRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        productId: String? = nil,
        quantity: Int? = nil,
        variantSku: String?? = nil
    ) -> RestockAndCascadeRequest {
        return RestockAndCascadeRequest(
            productId: productId ?? self.productId,
            quantity: quantity ?? self.quantity,
            variantSku: variantSku ?? self.variantSku
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - RestockAndCascadeResponse
struct RestockAndCascadeResponse: Codable, Sendable {
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case success = "success"
    }
}

// MARK: RestockAndCascadeResponse convenience initializers and mutators

extension RestockAndCascadeResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RestockAndCascadeResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        success: Bool? = nil
    ) -> RestockAndCascadeResponse {
        return RestockAndCascadeResponse(
            success: success ?? self.success
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SaleDoc
struct SaleDoc: Codable, Sendable {
    let buyerAddress: SaleDocBuyerAddress?
    let buyerName: String?
    let carrier: Carrier?
    let coverPhotoPath: String?
    let createdAt: CreatedAt
    let deletedAt: DeletedAt?
    let externalUrl: String?
    let isDeleted: Bool?
    let listingTitle: String?
    let notes: String?
    let platform: DecrementAndCascadeRequestPlatform
    let platformItemId: String?
    let platformOrderId: String?
    let priceSoldFor: Double
    let productId: String?
    let productTags: [String]?
    let quantity: Int?
    let shippedAt: ShippedAt?
    let shippingLabelCost: Double?
    let shippingRevenue: Double?
    let soldAt: SoldAt
    let source: Source?
    let status: SaleDocStatus
    let takeHome: Double?
    let thumbnailUrl: String?
    let trackingNumber: String?
    let updatedAt: UpdatedAt
    let userId: String
    let variantOptionValues: [String: String]?
    let variantSku: String?

    enum CodingKeys: String, CodingKey {
        case buyerAddress = "buyerAddress"
        case buyerName = "buyerName"
        case carrier = "carrier"
        case coverPhotoPath = "coverPhotoPath"
        case createdAt = "createdAt"
        case deletedAt = "deletedAt"
        case externalUrl = "externalUrl"
        case isDeleted = "isDeleted"
        case listingTitle = "listingTitle"
        case notes = "notes"
        case platform = "platform"
        case platformItemId = "platformItemId"
        case platformOrderId = "platformOrderId"
        case priceSoldFor = "priceSoldFor"
        case productId = "productId"
        case productTags = "productTags"
        case quantity = "quantity"
        case shippedAt = "shippedAt"
        case shippingLabelCost = "shippingLabelCost"
        case shippingRevenue = "shippingRevenue"
        case soldAt = "soldAt"
        case source = "source"
        case status = "status"
        case takeHome = "takeHome"
        case thumbnailUrl = "thumbnailUrl"
        case trackingNumber = "trackingNumber"
        case updatedAt = "updatedAt"
        case userId = "userId"
        case variantOptionValues = "variantOptionValues"
        case variantSku = "variantSku"
    }
}

// MARK: SaleDoc convenience initializers and mutators

extension SaleDoc {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SaleDoc.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        buyerAddress: SaleDocBuyerAddress?? = nil,
        buyerName: String?? = nil,
        carrier: Carrier?? = nil,
        coverPhotoPath: String?? = nil,
        createdAt: CreatedAt? = nil,
        deletedAt: DeletedAt?? = nil,
        externalUrl: String?? = nil,
        isDeleted: Bool?? = nil,
        listingTitle: String?? = nil,
        notes: String?? = nil,
        platform: DecrementAndCascadeRequestPlatform? = nil,
        platformItemId: String?? = nil,
        platformOrderId: String?? = nil,
        priceSoldFor: Double? = nil,
        productId: String?? = nil,
        productTags: [String]?? = nil,
        quantity: Int?? = nil,
        shippedAt: ShippedAt?? = nil,
        shippingLabelCost: Double?? = nil,
        shippingRevenue: Double?? = nil,
        soldAt: SoldAt? = nil,
        source: Source?? = nil,
        status: SaleDocStatus? = nil,
        takeHome: Double?? = nil,
        thumbnailUrl: String?? = nil,
        trackingNumber: String?? = nil,
        updatedAt: UpdatedAt? = nil,
        userId: String? = nil,
        variantOptionValues: [String: String]?? = nil,
        variantSku: String?? = nil
    ) -> SaleDoc {
        return SaleDoc(
            buyerAddress: buyerAddress ?? self.buyerAddress,
            buyerName: buyerName ?? self.buyerName,
            carrier: carrier ?? self.carrier,
            coverPhotoPath: coverPhotoPath ?? self.coverPhotoPath,
            createdAt: createdAt ?? self.createdAt,
            deletedAt: deletedAt ?? self.deletedAt,
            externalUrl: externalUrl ?? self.externalUrl,
            isDeleted: isDeleted ?? self.isDeleted,
            listingTitle: listingTitle ?? self.listingTitle,
            notes: notes ?? self.notes,
            platform: platform ?? self.platform,
            platformItemId: platformItemId ?? self.platformItemId,
            platformOrderId: platformOrderId ?? self.platformOrderId,
            priceSoldFor: priceSoldFor ?? self.priceSoldFor,
            productId: productId ?? self.productId,
            productTags: productTags ?? self.productTags,
            quantity: quantity ?? self.quantity,
            shippedAt: shippedAt ?? self.shippedAt,
            shippingLabelCost: shippingLabelCost ?? self.shippingLabelCost,
            shippingRevenue: shippingRevenue ?? self.shippingRevenue,
            soldAt: soldAt ?? self.soldAt,
            source: source ?? self.source,
            status: status ?? self.status,
            takeHome: takeHome ?? self.takeHome,
            thumbnailUrl: thumbnailUrl ?? self.thumbnailUrl,
            trackingNumber: trackingNumber ?? self.trackingNumber,
            updatedAt: updatedAt ?? self.updatedAt,
            userId: userId ?? self.userId,
            variantOptionValues: variantOptionValues ?? self.variantOptionValues,
            variantSku: variantSku ?? self.variantSku
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SaleDocBuyerAddress
struct SaleDocBuyerAddress: Codable, Sendable {
    let city: String?
    let country: String?
    let line1: String?
    let line2: String?
    let name: String?
    let state: String?
    let zip: String?

    enum CodingKeys: String, CodingKey {
        case city = "city"
        case country = "country"
        case line1 = "line1"
        case line2 = "line2"
        case name = "name"
        case state = "state"
        case zip = "zip"
    }
}

// MARK: SaleDocBuyerAddress convenience initializers and mutators

extension SaleDocBuyerAddress {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SaleDocBuyerAddress.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        city: String?? = nil,
        country: String?? = nil,
        line1: String?? = nil,
        line2: String?? = nil,
        name: String?? = nil,
        state: String?? = nil,
        zip: String?? = nil
    ) -> SaleDocBuyerAddress {
        return SaleDocBuyerAddress(
            city: city ?? self.city,
            country: country ?? self.country,
            line1: line1 ?? self.line1,
            line2: line2 ?? self.line2,
            name: name ?? self.name,
            state: state ?? self.state,
            zip: zip ?? self.zip
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - CreatedAt
struct CreatedAt: Codable, Sendable {
    let nanoseconds: Int
    let seconds: Int

    enum CodingKeys: String, CodingKey {
        case nanoseconds = "_nanoseconds"
        case seconds = "_seconds"
    }
}

// MARK: CreatedAt convenience initializers and mutators

extension CreatedAt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CreatedAt.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        nanoseconds: Int? = nil,
        seconds: Int? = nil
    ) -> CreatedAt {
        return CreatedAt(
            nanoseconds: nanoseconds ?? self.nanoseconds,
            seconds: seconds ?? self.seconds
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - DeletedAt
struct DeletedAt: Codable, Sendable {
    let nanoseconds: Int
    let seconds: Int

    enum CodingKeys: String, CodingKey {
        case nanoseconds = "_nanoseconds"
        case seconds = "_seconds"
    }
}

// MARK: DeletedAt convenience initializers and mutators

extension DeletedAt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DeletedAt.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        nanoseconds: Int? = nil,
        seconds: Int? = nil
    ) -> DeletedAt {
        return DeletedAt(
            nanoseconds: nanoseconds ?? self.nanoseconds,
            seconds: seconds ?? self.seconds
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ShippedAt
struct ShippedAt: Codable, Sendable {
    let nanoseconds: Int
    let seconds: Int

    enum CodingKeys: String, CodingKey {
        case nanoseconds = "_nanoseconds"
        case seconds = "_seconds"
    }
}

// MARK: ShippedAt convenience initializers and mutators

extension ShippedAt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ShippedAt.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        nanoseconds: Int? = nil,
        seconds: Int? = nil
    ) -> ShippedAt {
        return ShippedAt(
            nanoseconds: nanoseconds ?? self.nanoseconds,
            seconds: seconds ?? self.seconds
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SoldAt
struct SoldAt: Codable, Sendable {
    let nanoseconds: Int
    let seconds: Int

    enum CodingKeys: String, CodingKey {
        case nanoseconds = "_nanoseconds"
        case seconds = "_seconds"
    }
}

// MARK: SoldAt convenience initializers and mutators

extension SoldAt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SoldAt.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        nanoseconds: Int? = nil,
        seconds: Int? = nil
    ) -> SoldAt {
        return SoldAt(
            nanoseconds: nanoseconds ?? self.nanoseconds,
            seconds: seconds ?? self.seconds
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum Source: String, Codable, Sendable {
    case crossPostDrift = "cross-post-drift"
    case ebayPoll = "ebay-poll"
    case etsyPoll = "etsy-poll"
    case manual = "manual"
    case mercariScan = "mercari-scan"
}

enum SaleDocStatus: String, Codable, Sendable {
    case cancelled = "cancelled"
    case complete = "complete"
    case delivered = "delivered"
    case pending = "pending"
    case returned = "returned"
    case shipped = "shipped"
}

// MARK: - UpdatedAt
struct UpdatedAt: Codable, Sendable {
    let nanoseconds: Int
    let seconds: Int

    enum CodingKeys: String, CodingKey {
        case nanoseconds = "_nanoseconds"
        case seconds = "_seconds"
    }
}

// MARK: UpdatedAt convenience initializers and mutators

extension UpdatedAt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(UpdatedAt.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        nanoseconds: Int? = nil,
        seconds: Int? = nil
    ) -> UpdatedAt {
        return UpdatedAt(
            nanoseconds: nanoseconds ?? self.nanoseconds,
            seconds: seconds ?? self.seconds
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SuggestEtsyCategoryRequest
struct SuggestEtsyCategoryRequest: Codable, Sendable {
    let category: String?
    let credentialSet: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case category = "category"
        case credentialSet = "credentialSet"
        case title = "title"
    }
}

// MARK: SuggestEtsyCategoryRequest convenience initializers and mutators

extension SuggestEtsyCategoryRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SuggestEtsyCategoryRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        category: String?? = nil,
        credentialSet: String?? = nil,
        title: String?? = nil
    ) -> SuggestEtsyCategoryRequest {
        return SuggestEtsyCategoryRequest(
            category: category ?? self.category,
            credentialSet: credentialSet ?? self.credentialSet,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SuggestEtsyCategoryResponse
struct SuggestEtsyCategoryResponse: Codable, Sendable {
    let taxonomyId: Double
    let taxonomyName: String

    enum CodingKeys: String, CodingKey {
        case taxonomyId = "taxonomyId"
        case taxonomyName = "taxonomyName"
    }
}

// MARK: SuggestEtsyCategoryResponse convenience initializers and mutators

extension SuggestEtsyCategoryResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SuggestEtsyCategoryResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        taxonomyId: Double? = nil,
        taxonomyName: String? = nil
    ) -> SuggestEtsyCategoryResponse {
        return SuggestEtsyCategoryResponse(
            taxonomyId: taxonomyId ?? self.taxonomyId,
            taxonomyName: taxonomyName ?? self.taxonomyName
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SyncSalesRequest
struct SyncSalesRequest: Codable, Sendable {
    let platform: SyncSalesRequestPlatform?
    let since: SoldAtUnion?

    enum CodingKeys: String, CodingKey {
        case platform = "platform"
        case since = "since"
    }
}

// MARK: SyncSalesRequest convenience initializers and mutators

extension SyncSalesRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SyncSalesRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        platform: SyncSalesRequestPlatform?? = nil,
        since: SoldAtUnion?? = nil
    ) -> SyncSalesRequest {
        return SyncSalesRequest(
            platform: platform ?? self.platform,
            since: since ?? self.since
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum SyncSalesRequestPlatform: String, Codable, Sendable {
    case ebay = "ebay"
    case etsy = "etsy"
}

// MARK: - SyncSalesResponse
struct SyncSalesResponse: Codable, Sendable {
    let errors: [Error]
    let imported: Int
    let saleIds: [String]
    let skipped: Int

    enum CodingKeys: String, CodingKey {
        case errors = "errors"
        case imported = "imported"
        case saleIds = "saleIds"
        case skipped = "skipped"
    }
}

// MARK: SyncSalesResponse convenience initializers and mutators

extension SyncSalesResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SyncSalesResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        errors: [Error]? = nil,
        imported: Int? = nil,
        saleIds: [String]? = nil,
        skipped: Int? = nil
    ) -> SyncSalesResponse {
        return SyncSalesResponse(
            errors: errors ?? self.errors,
            imported: imported ?? self.imported,
            saleIds: saleIds ?? self.saleIds,
            skipped: skipped ?? self.skipped
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Error
struct Error: Codable, Sendable {
    let message: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case message = "message"
        case platform = "platform"
    }
}

// MARK: Error convenience initializers and mutators

extension Error {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Error.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        message: String? = nil,
        platform: String? = nil
    ) -> Error {
        return Error(
            message: message ?? self.message,
            platform: platform ?? self.platform
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - UpdateMercariListingStatusRequest
struct UpdateMercariListingStatusRequest: Codable, Sendable {
    let category: String?
    let error: String?
    let listingId: String?
    let productId: String
    let status: UpdateMercariListingStatusRequestStatus
    let syncedDescription: String?
    let syncedImages: [String]?
    let syncedPrice: Double?
    let syncedTitle: String?
    let url: String?
    let variantId: String?

    enum CodingKeys: String, CodingKey {
        case category = "category"
        case error = "error"
        case listingId = "listingId"
        case productId = "productId"
        case status = "status"
        case syncedDescription = "syncedDescription"
        case syncedImages = "syncedImages"
        case syncedPrice = "syncedPrice"
        case syncedTitle = "syncedTitle"
        case url = "url"
        case variantId = "variantId"
    }
}

// MARK: UpdateMercariListingStatusRequest convenience initializers and mutators

extension UpdateMercariListingStatusRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(UpdateMercariListingStatusRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        category: String?? = nil,
        error: String?? = nil,
        listingId: String?? = nil,
        productId: String? = nil,
        status: UpdateMercariListingStatusRequestStatus? = nil,
        syncedDescription: String?? = nil,
        syncedImages: [String]?? = nil,
        syncedPrice: Double?? = nil,
        syncedTitle: String?? = nil,
        url: String?? = nil,
        variantId: String?? = nil
    ) -> UpdateMercariListingStatusRequest {
        return UpdateMercariListingStatusRequest(
            category: category ?? self.category,
            error: error ?? self.error,
            listingId: listingId ?? self.listingId,
            productId: productId ?? self.productId,
            status: status ?? self.status,
            syncedDescription: syncedDescription ?? self.syncedDescription,
            syncedImages: syncedImages ?? self.syncedImages,
            syncedPrice: syncedPrice ?? self.syncedPrice,
            syncedTitle: syncedTitle ?? self.syncedTitle,
            url: url ?? self.url,
            variantId: variantId ?? self.variantId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum UpdateMercariListingStatusRequestStatus: String, Codable, Sendable {
    case active = "active"
    case draft = "draft"
    case error = "error"
    case inactive = "inactive"
    case sold = "sold"
}

// MARK: - UpdateMercariListingStatusResponse
struct UpdateMercariListingStatusResponse: Codable, Sendable {
    let ok: Bool

    enum CodingKeys: String, CodingKey {
        case ok = "ok"
    }
}

// MARK: UpdateMercariListingStatusResponse convenience initializers and mutators

extension UpdateMercariListingStatusResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(UpdateMercariListingStatusResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        ok: Bool? = nil
    ) -> UpdateMercariListingStatusResponse {
        return UpdateMercariListingStatusResponse(
            ok: ok ?? self.ok
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Helper functions for creating encoders and decoders

func newJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        decoder.dateDecodingStrategy = .iso8601
    }
    return decoder
}

func newJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        encoder.dateEncodingStrategy = .iso8601
    }
    return encoder
}

// MARK: - Encode/decode helpers

class JSONNull: Codable, Hashable {

    public static func == (lhs: JSONNull, rhs: JSONNull) -> Bool {
        return true
    }

    public var hashValue: Int {
        return 0
    }

    public func hash(into hasher: inout Hasher) {
        // No-op
    }

    public init() {}

    public required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if !container.decodeNil() {
            throw DecodingError.typeMismatch(JSONNull.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONNull"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

class JSONCodingKey: CodingKey {
    let key: String

    required init?(intValue: Int) {
        return nil
    }

    required init?(stringValue: String) {
        key = stringValue
    }

    var intValue: Int? {
        return nil
    }

    var stringValue: String {
        return key
    }
}

class JSONAny: Codable {

    let value: Any

    static func decodingError(forCodingPath codingPath: [CodingKey]) -> DecodingError {
        let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Cannot decode JSONAny")
        return DecodingError.typeMismatch(JSONAny.self, context)
    }

    static func encodingError(forValue value: Any, codingPath: [CodingKey]) -> EncodingError {
        let context = EncodingError.Context(codingPath: codingPath, debugDescription: "Cannot encode JSONAny")
        return EncodingError.invalidValue(value, context)
    }

    static func decode(from container: SingleValueDecodingContainer) throws -> Any {
        if let value = try? container.decode(Bool.self) {
            return value
        }
        if let value = try? container.decode(Int64.self) {
            return value
        }
        if let value = try? container.decode(Double.self) {
            return value
        }
        if let value = try? container.decode(String.self) {
            return value
        }
        if container.decodeNil() {
            return JSONNull()
        }
        throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout UnkeyedDecodingContainer) throws -> Any {
        if let value = try? container.decode(Bool.self) {
            return value
        }
        if let value = try? container.decode(Int64.self) {
            return value
        }
        if let value = try? container.decode(Double.self) {
            return value
        }
        if let value = try? container.decode(String.self) {
            return value
        }
        if let value = try? container.decodeNil() {
            if value {
                return JSONNull()
            }
        }
        if var container = try? container.nestedUnkeyedContainer() {
            return try decodeArray(from: &container)
        }
        if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self) {
            return try decodeDictionary(from: &container)
        }
        throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout KeyedDecodingContainer<JSONCodingKey>, forKey key: JSONCodingKey) throws -> Any {
        if let value = try? container.decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeNil(forKey: key) {
            if value {
                return JSONNull()
            }
        }
        if var container = try? container.nestedUnkeyedContainer(forKey: key) {
            return try decodeArray(from: &container)
        }
        if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key) {
            return try decodeDictionary(from: &container)
        }
        throw decodingError(forCodingPath: container.codingPath)
    }

    static func decodeArray(from container: inout UnkeyedDecodingContainer) throws -> [Any] {
        var arr: [Any] = []
        while !container.isAtEnd {
            let value = try decode(from: &container)
            arr.append(value)
        }
        return arr
    }

    static func decodeDictionary(from container: inout KeyedDecodingContainer<JSONCodingKey>) throws -> [String: Any] {
        var dict = [String: Any]()
        for key in container.allKeys {
            let value = try decode(from: &container, forKey: key)
            dict[key.stringValue] = value
        }
        return dict
    }

    static func encode(to container: inout UnkeyedEncodingContainer, array: [Any]) throws {
        for value in array {
            if let value = value as? Bool {
                try container.encode(value)
            } else if let value = value as? Int64 {
                try container.encode(value)
            } else if let value = value as? Double {
                try container.encode(value)
            } else if let value = value as? String {
                try container.encode(value)
            } else if value is JSONNull {
                try container.encodeNil()
            } else if let value = value as? [Any] {
                var container = container.nestedUnkeyedContainer()
                try encode(to: &container, array: value)
            } else if let value = value as? [String: Any] {
                var container = container.nestedContainer(keyedBy: JSONCodingKey.self)
                try encode(to: &container, dictionary: value)
            } else {
                throw encodingError(forValue: value, codingPath: container.codingPath)
            }
        }
    }

    static func encode(to container: inout KeyedEncodingContainer<JSONCodingKey>, dictionary: [String: Any]) throws {
        for (key, value) in dictionary {
            let key = JSONCodingKey(stringValue: key)!
            if let value = value as? Bool {
                try container.encode(value, forKey: key)
            } else if let value = value as? Int64 {
                try container.encode(value, forKey: key)
            } else if let value = value as? Double {
                try container.encode(value, forKey: key)
            } else if let value = value as? String {
                try container.encode(value, forKey: key)
            } else if value is JSONNull {
                try container.encodeNil(forKey: key)
            } else if let value = value as? [Any] {
                var container = container.nestedUnkeyedContainer(forKey: key)
                try encode(to: &container, array: value)
            } else if let value = value as? [String: Any] {
                var container = container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key)
                try encode(to: &container, dictionary: value)
            } else {
                throw encodingError(forValue: value, codingPath: container.codingPath)
            }
        }
    }

    static func encode(to container: inout SingleValueEncodingContainer, value: Any) throws {
        if let value = value as? Bool {
            try container.encode(value)
        } else if let value = value as? Int64 {
            try container.encode(value)
        } else if let value = value as? Double {
            try container.encode(value)
        } else if let value = value as? String {
            try container.encode(value)
        } else if value is JSONNull {
            try container.encodeNil()
        } else {
            throw encodingError(forValue: value, codingPath: container.codingPath)
        }
    }

    public required init(from decoder: Decoder) throws {
        if var arrayContainer = try? decoder.unkeyedContainer() {
            self.value = try JSONAny.decodeArray(from: &arrayContainer)
        } else if var container = try? decoder.container(keyedBy: JSONCodingKey.self) {
            self.value = try JSONAny.decodeDictionary(from: &container)
        } else {
            let container = try decoder.singleValueContainer()
            self.value = try JSONAny.decode(from: container)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let arr = self.value as? [Any] {
            var container = encoder.unkeyedContainer()
            try JSONAny.encode(to: &container, array: arr)
        } else if let dict = self.value as? [String: Any] {
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            try JSONAny.encode(to: &container, dictionary: dict)
        } else {
            var container = encoder.singleValueContainer()
            try JSONAny.encode(to: &container, value: self.value)
        }
    }
}
