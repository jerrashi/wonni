import XCTest
@testable import wonni

/// The pure half of "drafts from a pasted list": how a `bulkDraftsFromText` proposal
/// lands on an `Item`, and the placeholder card a photo-less proposal gets so the
/// draft is still visible/publishable.
final class BulkTextDraftMappingTests: XCTestCase {

    private func proposal(
        title: String = "Super Smash Bros. Brawl (Nintendo Wii) Complete in Box",
        shortTitle: String = "Super Smash Bros Brawl Wii CIB",
        condition: Condition = .good,
        price: Double? = 32,
        priceSource: PriceSource = .comps,
        marketPrice: Double? = nil,
        marketPriceSource: MarketPriceSource? = nil,
        imageUrls: [String] = ["https://i.ebayimg.com/a.jpg"],
        imageSource: ImageSource = .ebay,
        isBundle: Bool = false,
        bundleItems: [String] = []
    ) -> Draft {
        Draft(
            brand: "Nintendo",
            bundleItems: bundleItems,
            category: "Video Games & Consoles > Video Games",
            comps: [],
            condition: condition,
            description: "Complete in box with manual.",
            ebayCategoryId: "139973",
            ebayConditionId: "4000",
            epid: "24070872136",
            imageSource: imageSource,
            imageUrls: imageUrls,
            isBundle: isBundle,
            itemSpecifics: ["Platform": "Nintendo Wii", "Game Name": "Super Smash Bros. Brawl"],
            marketPrice: marketPrice,
            marketPriceSource: marketPriceSource,
            priceSource: priceSource,
            quantity: 1,
            shortTitle: shortTitle,
            similarItemId: "v1|398452119919|0",
            sourceText: "Super smash bros brawl",
            suggestedPrice: price,
            tags: ["wii", "nintendo"],
            title: title
        )
    }

    func testApplyFillsAISuggestionsNotUserFields() {
        let item = Item(firestoreListingId: "p1")
        BulkTextDraftMapper.apply(proposal(), to: item, aiModel: "gemini-flash-lite-latest", aiPromptVersion: "2026-10-01.1")

        XCTAssertEqual(item.aiSuggestedTitle, "Super Smash Bros Brawl Wii CIB")
        XCTAssertNil(item.userEditedTitle)
        XCTAssertEqual(item.aiSuggestedPrice, 32)
        XCTAssertNil(item.userEditedPrice)
        XCTAssertEqual(item.aiSuggestedDescription, "Complete in box with manual.")
        XCTAssertEqual(item.condition, ItemCondition.good.rawValue)
        XCTAssertEqual(item.aiSuggestedCategory, "Video Games & Consoles > Video Games")
        XCTAssertEqual(item.aiSuggestedBrand, "Nintendo")
        XCTAssertEqual(item.tags, ["wii", "nintendo"])
        XCTAssertEqual(item.aiModel, "gemini-flash-lite-latest")
        XCTAssertEqual(item.aiPromptVersion, "2026-10-01.1")
        XCTAssertEqual(item.personalNote, "From list: Super smash bros brawl")
        // "Sell similar" carry-over, read back by ebayCreateListing via products/{id}.
        XCTAssertEqual(item.ebayCategoryId, "139973")
        XCTAssertEqual(item.itemSpecifics, ["Platform": "Nintendo Wii", "Game Name": "Super Smash Bros. Brawl"])
    }

    func testApplyMapsCanonicalConditionOntoItemCondition() {
        let item = Item(firestoreListingId: "p2")
        BulkTextDraftMapper.apply(proposal(condition: .likenew), to: item, aiModel: "m", aiPromptVersion: "v")
        XCTAssertEqual(item.condition, ItemCondition.likeNew.rawValue)
    }

    func testApplyFallsBackToLongTitleWhenShortTitleEmpty() {
        let item = Item(firestoreListingId: "p3")
        BulkTextDraftMapper.apply(proposal(shortTitle: ""), to: item, aiModel: "m", aiPromptVersion: "v")
        XCTAssertEqual(item.aiSuggestedTitle, "Super Smash Bros. Brawl (Nintendo Wii) Complete in Box")
    }

    func testUserStatedPriceLandsInTheUserFieldWithCompsAsTheSuggestion() {
        let item = Item(firestoreListingId: "p-user-price")
        let stated = proposal(price: 25, priceSource: .user, marketPrice: 32, marketPriceSource: .comps)
        BulkTextDraftMapper.apply(stated, to: item, aiModel: "m", aiPromptVersion: "v")
        XCTAssertEqual(item.userEditedPrice, 25)
        XCTAssertEqual(item.aiSuggestedPrice, 32)
        XCTAssertEqual(BulkTextDraftMapper.priceLabel(stated), "Your price · eBay comps $32")
        XCTAssertEqual(BulkTextDraftMapper.priceLabel(proposal(price: 25, priceSource: .user, marketPrice: 30, marketPriceSource: .ai)), "Your price · AI estimate $30")
        XCTAssertEqual(BulkTextDraftMapper.priceLabel(proposal(price: 25, priceSource: .user)), "Your price")

        BulkTextDraftMapper.apply(proposal(price: 32), to: item, aiModel: "m", aiPromptVersion: "v")
        XCTAssertNil(item.userEditedPrice)
        XCTAssertEqual(item.aiSuggestedPrice, 32)
    }

    func testLabelsDescribeSources() {
        XCTAssertEqual(BulkTextDraftMapper.priceLabel(proposal()), "eBay comps")
        XCTAssertEqual(BulkTextDraftMapper.priceLabel(proposal(price: 20, priceSource: .ai)), "AI estimate")
        XCTAssertEqual(BulkTextDraftMapper.priceLabel(proposal(price: nil, priceSource: .none)), "No price found")

        XCTAssertEqual(BulkTextDraftMapper.photoLabel(proposal()), "eBay seller photo")
        XCTAssertEqual(BulkTextDraftMapper.photoLabel(proposal(imageUrls: ["a", "b", "c"])), "3 eBay seller photos")
        XCTAssertEqual(BulkTextDraftMapper.photoLabel(proposal(imageSource: .google)), "Web photo")
        XCTAssertEqual(BulkTextDraftMapper.photoLabel(proposal(imageSource: .generated)), "AI-generated photo")
        XCTAssertEqual(BulkTextDraftMapper.photoLabel(proposal(imageUrls: [], imageSource: .none)), "No photo found — placeholder, replace before posting")
    }

    func testNeedsPhotoOnlyWhenNothingWasFound() {
        XCTAssertFalse(BulkTextDraftMapper.needsPhoto(proposal()))
        XCTAssertFalse(BulkTextDraftMapper.needsPhoto(proposal(imageSource: .google)))
        XCTAssertTrue(BulkTextDraftMapper.needsPhoto(proposal(imageUrls: [], imageSource: .none)))
    }

    func testConsentedGenerationRelabelsTheProposal() {
        let generated = proposal(imageUrls: [], imageSource: .none).with(imageSource: .generated, imageUrls: ["https://storage.googleapis.com/b/users/u/generated/1.png"])
        XCTAssertEqual(generated.imageSource, .generated)
        XCTAssertFalse(BulkTextDraftMapper.needsPhoto(generated))
        XCTAssertEqual(BulkTextDraftMapper.photoLabel(generated), "AI-generated photo")
    }

    func testPlaceholderImageIsSquareAndEncodable() {
        let image = BulkTextDraftMapper.placeholderImage(title: "Mario Strikers Charged Wii", size: 256)
        XCTAssertEqual(image.size.width, 256)
        XCTAssertEqual(image.size.height, 256)
        XCTAssertNotNil(image.jpegData(compressionQuality: 0.8))
    }

    func testResponseDecodesFromCallablePayload() throws {
        let payload: [String: Any] = [
            "context": "Nintendo Wii games, complete in box",
            "aiModel": "gemini-flash-lite-latest",
            "aiPromptVersion": "2026-10-01.1",
            "drafts": [[
                "title": "Just Dance 4, 2015 & 2014 Wii Bundle (3 Games, CIB)",
                "shortTitle": "Just Dance 4 2015 2014 Wii Bundle CIB",
                "description": "Three games.",
                "condition": "good",
                "tags": ["wii"],
                "isBundle": true,
                "bundleItems": ["Just Dance 4", "Just Dance 2015", "Just Dance 2014"],
                "quantity": 1,
                "suggestedPrice": 30,
                "priceSource": "comps",
                "imageUrls": ["https://i.ebayimg.com/1.jpg", "https://i.ebayimg.com/2.jpg"],
                "imageSource": "ebay",
                "comps": [["title": "lot", "price": 30, "itemWebUrl": NSNull()]],
                "similarItemId": "v1|1|0",
                "ebayCategoryId": "139973",
                "itemSpecifics": ["Platform": "Nintendo Wii"],
                "sourceText": "bundle 1: just dance 4, just dance 2015, just dance 2014"
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try JSONDecoder().decode(BulkDraftsFromTextResponse.self, from: data)
        XCTAssertEqual(response.drafts.count, 1)
        XCTAssertTrue(response.drafts[0].isBundle)
        XCTAssertEqual(response.drafts[0].bundleItems.count, 3)
        XCTAssertEqual(response.drafts[0].imageUrls.count, 2)
        XCTAssertNil(response.drafts[0].comps[0].itemWebUrl)
        XCTAssertEqual(response.drafts[0].ebayCategoryId, "139973")
        XCTAssertEqual(response.drafts[0].itemSpecifics?["Platform"], "Nintendo Wii")
        XCTAssertNil(response.drafts[0].epid)
    }
}
