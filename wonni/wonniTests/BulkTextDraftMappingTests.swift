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
        bundleItems: [String] = [],
        sourceText: String = "Super smash bros brawl",
        weightOz: Double? = nil,
        included: Included? = nil,
        media: Media? = nil,
        photoMatch: PhotoMatch? = nil,
        photoCandidates: [PhotoCandidate]? = nil,
        searchQuery: String? = nil,
        sourceUrl: String? = nil,
        sourcePrice: Double? = nil
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
            heightIn: weightOz == nil ? nil : 1,
            imageSource: imageSource,
            imageUrls: imageUrls,
            included: included,
            isBundle: isBundle,
            itemSpecifics: ["Platform": "Nintendo Wii", "Game Name": "Super Smash Bros. Brawl"],
            lengthIn: weightOz == nil ? nil : 7.5,
            marketPrice: marketPrice,
            marketPriceSource: marketPriceSource,
            media: media,
            photoCandidates: photoCandidates,
            photoMatch: photoMatch,
            priceSource: priceSource,
            quantity: 1,
            searchQuery: searchQuery,
            shortTitle: shortTitle,
            similarItemId: "v1|398452119919|0",
            source: sourceUrl == nil ? nil : .amazon,
            sourceId: sourceUrl == nil ? nil : "B0CHX1W1XY",
            sourcePrice: sourcePrice,
            sourceText: sourceText,
            sourceUrl: sourceUrl,
            suggestedPrice: price,
            tags: ["wii", "nintendo"],
            title: title,
            weightOz: weightOz,
            widthIn: weightOz == nil ? nil : 5.5
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

    /// A bare disc or cartridge with no matching photo gets a drawn disc / cartridge;
    /// everything else (boxed, sealed, unstated, non-media) keeps the plain card.
    func testPlaceholderStyleFollowsWhatTheListingIncludes() {
        XCTAssertEqual(BulkTextDraftMapper.placeholderStyle(for: proposal(included: .loose, media: .disc)), .disc)
        XCTAssertEqual(BulkTextDraftMapper.placeholderStyle(for: proposal(included: .loose, media: .cartridge)), .cartridge)
        XCTAssertEqual(BulkTextDraftMapper.placeholderStyle(for: proposal(included: .loose, media: .other)), .card)
        XCTAssertEqual(BulkTextDraftMapper.placeholderStyle(for: proposal(included: .complete, media: .disc)), .card)
        XCTAssertEqual(BulkTextDraftMapper.placeholderStyle(for: proposal(included: .unknown, media: .cartridge)), .card)
        // A response from a server older than these fields.
        XCTAssertEqual(BulkTextDraftMapper.placeholderStyle(for: proposal()), .card)
    }

    func testEveryPlaceholderStyleRendersADifferentSquareImage() {
        let styles: [BulkTextDraftMapper.PlaceholderStyle] = [.card, .disc, .cartridge]
        let images = styles.map { BulkTextDraftMapper.placeholderImage(title: "Wii Sports", style: $0, size: 256) }
        for image in images {
            XCTAssertEqual(image.size, CGSize(width: 256, height: 256))
            XCTAssertNotNil(image.jpegData(compressionQuality: 0.8))
        }
        let data = images.compactMap { $0.pngData() }
        XCTAssertEqual(Set(data).count, 3)
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
                "weightOz": 12,
                "sourceText": "bundle 1: just dance 4, just dance 2015, just dance 2014"
            ]],
            "remaining": [[
                "title": "Mario Kart Wii (Nintendo Wii) Complete in Box",
                "shortTitle": "Mario Kart Wii CIB",
                "description": "Complete in box.",
                "condition": "good",
                "tags": ["wii"],
                "isBundle": false,
                "bundleItems": [],
                "quantity": 1,
                "sourceText": "mario kart",
                "searchQuery": "Mario Kart Wii CIB",
                "componentQueries": [],
                "userPrice": 10
            ]],
            "needsDecision": [[
                "sourceText": "amazing spider man issues 211-212",
                "title": "Amazing Spider-Man #211-212",
                "memberTitles": ["Amazing Spider-Man #211", "Amazing Spider-Man #212"],
                "asBundle": ["title": "Amazing Spider-Man #211-212 Lot", "shortTitle": "ASM 211-212 Lot", "description": "d", "condition": "good", "tags": [], "isBundle": true, "bundleItems": ["Amazing Spider-Man #211", "Amazing Spider-Man #212"], "quantity": 1, "sourceText": "amazing spider man issues 211-212", "searchQuery": "amazing spider-man 211 212", "componentQueries": ["amazing spider-man 211", "amazing spider-man 212"]],
                "asIndividual": [
                    ["title": "Amazing Spider-Man #211", "shortTitle": "ASM #211", "description": "d", "condition": "good", "tags": [], "isBundle": false, "bundleItems": [], "quantity": 1, "sourceText": "amazing spider man issues 211-212", "searchQuery": "amazing spider-man 211", "componentQueries": []],
                    ["title": "Amazing Spider-Man #212", "shortTitle": "ASM #212", "description": "d", "condition": "good", "tags": [], "isBundle": false, "bundleItems": [], "quantity": 1, "sourceText": "amazing spider man issues 211-212", "searchQuery": "amazing spider-man 212", "componentQueries": []]
                ]
            ]],
            "links": [
                ["url": "https://www.amazon.com/Spigen/dp/B0CHX1W1XY", "source": "amazon", "status": "ok", "title": "Spigen Case"],
                ["url": "https://a.co/d/3xYz12Q", "source": "amazon", "status": "partial", "title": "Sony WH 1000XM5", "error": "Amazon returned a bot check; using the link's own words."]
            ],
            "unparsedText": ""
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try JSONDecoder().decode(ProposeResponse.self, from: data)
        XCTAssertEqual(response.needsDecision?.count, 1)
        XCTAssertEqual(response.needsDecision?[0].asIndividual.count, 2)
        XCTAssertEqual(response.links?[1].status, .partial)
        XCTAssertEqual(response.drafts.count, 1)
        XCTAssertTrue(response.drafts[0].isBundle)
        XCTAssertEqual(response.drafts[0].bundleItems.count, 3)
        XCTAssertEqual(response.drafts[0].imageUrls.count, 2)
        XCTAssertNil(response.drafts[0].comps[0].itemWebUrl)
        XCTAssertEqual(response.drafts[0].ebayCategoryId, "139973")
        XCTAssertEqual(response.drafts[0].itemSpecifics?["Platform"], "Nintendo Wii")
        XCTAssertNil(response.drafts[0].epid)
        XCTAssertEqual(response.drafts[0].weightOz, 12)

        // The un-enriched tail must survive the round trip back to the server intact:
        // it is sent as `pendingItems` exactly as it was received.
        XCTAssertEqual(response.remaining.count, 1)
        let resent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response.remaining)) as? [[String: Any]]
        XCTAssertEqual(resent?.first?["searchQuery"] as? String, "Mario Kart Wii CIB")
        XCTAssertEqual(resent?.first?["userPrice"] as? Double, 10)
        XCTAssertEqual(resent?.first?["sourceText"] as? String, "mario kart")
        XCTAssertNil(resent?.first?["brand"], "absent optionals must stay absent, not become null")
    }

    // MARK: Shipping estimates

    func testShippingEstimatesLandOnTheDraftSoNoSecondAIPassIsNeeded() {
        let item = Item(firestoreListingId: "p-ship")
        BulkTextDraftMapper.apply(proposal(weightOz: 6), to: item, aiModel: "m", aiPromptVersion: "v")
        XCTAssertEqual(item.weightLbs ?? 0, 0.375, accuracy: 0.0001)
        XCTAssertEqual(item.lengthIn, 7.5)
        XCTAssertEqual(item.widthIn, 5.5)
        XCTAssertEqual(item.heightIn, 1)

        let bare = Item(firestoreListingId: "p-no-ship")
        BulkTextDraftMapper.apply(proposal(), to: bare, aiModel: "m", aiPromptVersion: "v")
        XCTAssertNil(bare.weightLbs)
        XCTAssertNil(bare.lengthIn)
    }

    // MARK: Leftover text

    func testLeftoverTextKeepsContextOrderAndGroupPrices() {
        let lines = [
            BulkTextDraftMapper.LeftoverLine(sourceText: "mario kart wii", userPrice: 10),
            BulkTextDraftMapper.LeftoverLine(sourceText: "zelda twilight princess $25", userPrice: 25),
            BulkTextDraftMapper.LeftoverLine(sourceText: "  wii fit (no board) ", userPrice: nil),
            BulkTextDraftMapper.LeftoverLine(sourceText: "okami", userPrice: 12.5)
        ]
        let text = BulkTextDraftMapper.leftoverText(context: "Wii games, complete in box", lines: lines, unparsedText: "\nand a gamecube controller\n")
        XCTAssertEqual(text, """
        Wii games, complete in box:
        mario kart wii $10
        zelda twilight princess $25
        wii fit (no board)
        okami $12.50
        and a gamecube controller
        """)
    }

    func testLeftoverTextIsEmptyWhenEverythingWasConverted() {
        XCTAssertEqual(BulkTextDraftMapper.leftoverText(context: "Wii games", lines: [], unparsedText: "  "), "")
        // Only an unparsed tail: no header invented for it.
        XCTAssertEqual(BulkTextDraftMapper.leftoverText(context: "Wii games", lines: [], unparsedText: "ps2 games: gta 3"), "ps2 games: gta 3")
    }

    func testLeftoverLineFromAPreparedDraftCarriesOnlyAUserPrice() {
        let userPriced = BulkTextDraftMapper.LeftoverLine(proposal(price: 30, priceSource: .user, sourceText: "smash"))
        XCTAssertEqual(userPriced, BulkTextDraftMapper.LeftoverLine(sourceText: "smash", userPrice: 30))
        // A comps price is ours, not the user's: it must not be written into their text.
        let compsPriced = BulkTextDraftMapper.LeftoverLine(proposal(price: 32, priceSource: .comps, sourceText: "smash"))
        XCTAssertNil(compsPriced.userPrice)
    }

    // MARK: Photo chooser (2026-10-14)

    private func candidate(_ id: String, strong: Bool, included: Included = .complete) -> PhotoCandidate {
        PhotoCandidate(imageUrl: "https://i.ebayimg.com/\(id)/s-l1600.jpg", included: included, itemId: id, itemWebUrl: nil, markers: [], price: 20, strong: strong, title: "Listing \(id)")
    }

    func testApplyStoresTheChooserStateAndCandidatesRoundTrip() {
        let item = Item(firestoreListingId: "p-chooser")
        let list = [candidate("a", strong: true), candidate("b", strong: false, included: .loose)]
        BulkTextDraftMapper.apply(proposal(included: .complete, photoMatch: .photoMatchWeak, photoCandidates: list, searchQuery: "Mario Strikers Charged Wii"), to: item, aiModel: "m", aiPromptVersion: "v")
        XCTAssertEqual(item.photoMatch, "weak")
        XCTAssertEqual(item.photoSearchQuery, "Mario Strikers Charged Wii")
        XCTAssertEqual(item.includedState, "complete")
        XCTAssertEqual(BulkTextDraftMapper.storedCandidates(item.photoCandidatesData), list)

        // An older server sends none of it: nothing stored, no badge.
        let plain = Item(firestoreListingId: "p-old")
        BulkTextDraftMapper.apply(proposal(), to: plain, aiModel: "m", aiPromptVersion: "v")
        XCTAssertNil(plain.photoMatch)
        XCTAssertNil(plain.photoCandidatesData)
        XCTAssertEqual(BulkTextDraftMapper.storedCandidates(plain.photoCandidatesData), [])
        XCTAssertNil(BulkTextDraftMapper.photoBadgeText(photoMatch: plain.photoMatch))
    }

    func testBadgeOnlyOnWeakOrEmptyMatches() {
        XCTAssertNil(BulkTextDraftMapper.photoBadgeText(photoMatch: "strong"))
        XCTAssertNil(BulkTextDraftMapper.photoBadgeText(photoMatch: nil))
        XCTAssertNil(BulkTextDraftMapper.photoBadgeText(photoMatch: "garbage"))
        XCTAssertEqual(BulkTextDraftMapper.photoBadgeText(photoMatch: "weak"), "Photo may not match · Choose photos")
        XCTAssertEqual(BulkTextDraftMapper.photoBadgeText(photoMatch: "none"), "No photo found · Choose photos")
    }

    func testIncludedLabelsAndBundleHeuristic() {
        XCTAssertEqual(BulkTextDraftMapper.includedLabel(.complete), "Complete in box")
        XCTAssertEqual(BulkTextDraftMapper.includedLabel(.loose), "Loose")
        XCTAssertEqual(BulkTextDraftMapper.includedLabel(.sealed), "Sealed")
        XCTAssertEqual(BulkTextDraftMapper.includedLabel(.packaging), "Box or case only")
        XCTAssertNil(BulkTextDraftMapper.includedLabel(.unknown))
        XCTAssertTrue(BulkTextDraftMapper.looksLikeBundle(title: "Just Dance 4, 2015 & 2014 Wii Bundle (3 Games, CIB)"))
        XCTAssertTrue(BulkTextDraftMapper.looksLikeBundle(title: "Lot of 5 PS2 games"))
        XCTAssertFalse(BulkTextDraftMapper.looksLikeBundle(title: "Camelot Wii CIB"))
        XCTAssertFalse(BulkTextDraftMapper.looksLikeBundle(title: "Super Smash Bros Brawl Wii CIB"))
    }

    // MARK: textToListings — links and multi-item entries

    func testApplyStoresTheLinkProvenanceAndCost() {
        let item = Item(firestoreListingId: "p9")
        BulkTextDraftMapper.apply(proposal(price: 12, priceSource: .ai, sourceUrl: "https://www.amazon.com/Spigen/dp/B0CHX1W1XY", sourcePrice: 15.99), to: item, aiModel: "m", aiPromptVersion: "v")
        XCTAssertEqual(item.sourceUrl, "https://www.amazon.com/Spigen/dp/B0CHX1W1XY")
        XCTAssertEqual(item.sourceName, "amazon")
        XCTAssertEqual(item.sourcePrice, 15.99)
        XCTAssertEqual(item.aiSuggestedPrice, 12, "the cost never becomes the asking price")
        XCTAssertNil(item.userEditedPrice)

        let plain = Item(firestoreListingId: "p10")
        BulkTextDraftMapper.apply(proposal(), to: plain, aiModel: "m", aiPromptVersion: "v")
        XCTAssertNil(plain.sourceUrl)
        XCTAssertNil(plain.sourcePrice)
        XCTAssertNil(plain.sourceName)
    }

    private func pending(_ title: String, isBundle: Bool = false, userPrice: Double? = nil) -> Remaining {
        Remaining(brand: nil, bundleItems: isBundle ? ["a", "b"] : [], category: nil, componentQueries: [], condition: .good, description: "d", heightIn: nil, included: nil, isBundle: isBundle, lengthIn: nil, links: nil, media: nil, members: nil, quantity: 1, searchQuery: title, shortTitle: title, source: nil, sourceText: "src", suggestedPrice: nil, tags: [], title: title, userPrice: userPrice, weightOz: nil, widthIn: nil)
    }

    func testDecisionAnswersBecomePendingItemsWithIndividualAsTheDefault() {
        let comics = ListingDecision(asBundle: pending("ASM 211-213 Lot", isBundle: true, userPrice: 30), asIndividual: [pending("ASM #211"), pending("ASM #212"), pending("ASM #213")], memberTitles: ["ASM #211", "ASM #212", "ASM #213"], sourceText: "asm 211-213", title: "ASM 211-213")
        let pokemon = ListingDecision(asBundle: pending("Pokemon Red Blue Yellow Lot", isBundle: true), asIndividual: [pending("Pokemon Red"), pending("Pokemon Blue"), pending("Pokemon Yellow")], memberTitles: ["Red", "Blue", "Yellow"], sourceText: "red blue yellow", title: "Pokemon RBY")

        let defaults = BulkTextDraftMapper.pendingItems(for: [comics, pokemon], choices: [:])
        XCTAssertEqual(defaults.map(\.title), ["ASM #211", "ASM #212", "ASM #213", "Pokemon Red", "Pokemon Blue", "Pokemon Yellow"])

        let mixed = BulkTextDraftMapper.pendingItems(for: [comics, pokemon], choices: [1: .bundle])
        XCTAssertEqual(mixed.map(\.title), ["ASM #211", "ASM #212", "ASM #213", "Pokemon Red Blue Yellow Lot"])
        XCTAssertTrue(mixed[3].isBundle)

        let bundles = BulkTextDraftMapper.pendingItems(for: [comics], choices: [0: .bundle])
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles[0].userPrice, 30, "the price the user wrote for the whole entry stays on the bundle")

        XCTAssertEqual(BulkTextDecisionSheet.shortMember("Amazing Spider-Man #211"), "#211")
        XCTAssertEqual(BulkTextDecisionSheet.shortMember("Pokemon Blue"), "Pokemon Blue")
    }

    func testLinkSummaryLinesGroupReadLinksAndNameTheFailedOnes() {
        XCTAssertEqual(BulkTextDraftMapper.linkSummaryLines([]), [])
        let lines = BulkTextDraftMapper.linkSummaryLines([
            LinkOutcome(error: nil, source: .amazon, status: .ok, title: "Spigen", url: "https://www.amazon.com/Spigen/dp/B0CHX1W1XY"),
            LinkOutcome(error: nil, source: .ebay, status: .ok, title: "Pokemon Blue", url: "https://www.ebay.com/itm/137561869182"),
            LinkOutcome(error: nil, source: .amazon, status: .ok, title: "Sony", url: "https://www.amazon.com/dp/B09XS7JWHH"),
            LinkOutcome(error: "Amazon returned a bot check; using the link's own words.", source: .amazon, status: .partial, title: "Sony WH 1000XM5", url: "https://a.co/d/3xYz12Q"),
            LinkOutcome(error: "The page returned 404.", source: .web, status: .failed, title: nil, url: "https://example.com/gone"),
        ])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "3 links read (2 from Amazon, 1 from eBay). Their photos and prices paid are on the drafts.")
        XCTAssertTrue(lines[1].hasPrefix("a.co/d/3xYz12Q could not be fully read (Amazon showed a bot check)"), lines[1])
        XCTAssertEqual(lines[2], "example.com/gone could not be read: The page returned 404.")
    }
}
