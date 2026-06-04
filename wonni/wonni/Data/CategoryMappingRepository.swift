//
//  CategoryMappingRepository.swift
//  wonni
//

import Foundation
import FirebaseFirestore

struct CategoryMapping: Codable {
    let canonical: String   // "Electronics > Audio > Headphones"
    let ebay: Int           // 112529
    let mercari: String     // "electronics"
}

actor CategoryMappingRepository {
    static let shared = CategoryMappingRepository()

    private var mappings: [CategoryMapping] = []
    private var lastFetched: Date? = nil
    private let ttl: TimeInterval = 7 * 24 * 60 * 60   // 7 days
    private let udMappingsKey = "wonni_categoryMappings"
    private let udDateKey = "wonni_categoryMappingsFetchDate"

    private static let fallback: [CategoryMapping] = [
        // Electronics
        .init(canonical: "Electronics > Audio > Headphones",        ebay: 112529,  mercari: "electronics"),
        .init(canonical: "Electronics > Audio > Speakers",          ebay: 14990,   mercari: "electronics"),
        .init(canonical: "Electronics > Audio",                     ebay: 293,     mercari: "electronics"),
        .init(canonical: "Electronics > Cell Phones & Accessories", ebay: 15032,   mercari: "electronics"),
        .init(canonical: "Electronics > Computers & Tablets",       ebay: 58058,   mercari: "electronics"),
        .init(canonical: "Electronics > Cameras & Photo",           ebay: 625,     mercari: "electronics"),
        .init(canonical: "Electronics > Video Games & Consoles",    ebay: 1249,    mercari: "electronics"),
        .init(canonical: "Electronics > TV & Home Video",           ebay: 32852,   mercari: "electronics"),
        .init(canonical: "Electronics > Wearable Technology",       ebay: 184281,  mercari: "electronics"),
        .init(canonical: "Electronics",                             ebay: 293,     mercari: "electronics"),
        // Clothing
        .init(canonical: "Clothing > Men's Clothing",               ebay: 1059,    mercari: "mens"),
        .init(canonical: "Clothing > Women's Clothing",             ebay: 15724,   mercari: "womens"),
        .init(canonical: "Clothing > Men's Shoes",                  ebay: 93427,   mercari: "mens"),
        .init(canonical: "Clothing > Women's Shoes",                ebay: 3034,    mercari: "womens"),
        .init(canonical: "Clothing > Kids & Baby",                  ebay: 171146,  mercari: "kids"),
        .init(canonical: "Clothing, Shoes & Accessories",           ebay: 11450,   mercari: "womens"),
        // Books & Media
        .init(canonical: "Books, Movies & Music > Books",           ebay: 267,     mercari: "other"),
        .init(canonical: "Books, Movies & Music > Music > CDs",     ebay: 176984,  mercari: "other"),
        .init(canonical: "Books, Movies & Music > Movies",          ebay: 617,     mercari: "other"),
        .init(canonical: "Books, Movies & Music > Vinyl Records",   ebay: 176985,  mercari: "other"),
        .init(canonical: "Books, Movies & Music",                   ebay: 11232,   mercari: "other"),
        // Sporting Goods
        .init(canonical: "Sporting Goods > Exercise & Fitness",     ebay: 15273,   mercari: "sports"),
        .init(canonical: "Sporting Goods > Outdoor Sports",         ebay: 888,     mercari: "sports"),
        .init(canonical: "Sporting Goods > Team Sports",            ebay: 159043,  mercari: "sports"),
        .init(canonical: "Sporting Goods",                          ebay: 888,     mercari: "sports"),
        // Toys & Hobbies
        .init(canonical: "Toys & Hobbies > Action Figures",         ebay: 246,     mercari: "toys"),
        .init(canonical: "Toys & Hobbies > Building Toys",          ebay: 11731,   mercari: "toys"),
        .init(canonical: "Toys & Hobbies > Diecast & Vehicles",     ebay: 222,     mercari: "toys"),
        .init(canonical: "Toys & Hobbies > Dolls & Bears",          ebay: 237,     mercari: "toys"),
        .init(canonical: "Toys & Hobbies > Board Games",            ebay: 19121,   mercari: "toys"),
        .init(canonical: "Toys & Hobbies > Video Games",            ebay: 1249,    mercari: "electronics"),
        .init(canonical: "Toys & Hobbies",                          ebay: 220,     mercari: "toys"),
        // Home & Garden
        .init(canonical: "Home & Garden > Kitchen & Dining",        ebay: 20625,   mercari: "kitchen"),
        .init(canonical: "Home & Garden > Furniture",               ebay: 3197,    mercari: "furniture"),
        .init(canonical: "Home & Garden > Tools",                   ebay: 631,     mercari: "other"),
        .init(canonical: "Home & Garden > Bedding",                 ebay: 20444,   mercari: "other"),
        .init(canonical: "Home & Garden",                           ebay: 11700,   mercari: "other"),
        // Collectibles
        .init(canonical: "Collectibles > Trading Cards > Sports",   ebay: 212,     mercari: "other"),
        .init(canonical: "Collectibles > Trading Cards > CCG",      ebay: 2536,    mercari: "other"),
        .init(canonical: "Collectibles > Comics",                   ebay: 63,      mercari: "other"),
        .init(canonical: "Collectibles > Coins",                    ebay: 11116,   mercari: "other"),
        .init(canonical: "Collectibles",                            ebay: 1,       mercari: "other"),
        // Jewelry & Watches
        .init(canonical: "Jewelry & Watches > Watches",             ebay: 14324,   mercari: "accessories"),
        .init(canonical: "Jewelry & Watches > Fashion Jewelry",     ebay: 10968,   mercari: "accessories"),
        .init(canonical: "Jewelry & Watches",                       ebay: 281,     mercari: "accessories"),
        // Baby
        .init(canonical: "Baby > Strollers",                        ebay: 66707,   mercari: "baby"),
        .init(canonical: "Baby > Car Seats",                        ebay: 66709,   mercari: "baby"),
        .init(canonical: "Baby > Clothing",                         ebay: 3082,    mercari: "baby"),
        .init(canonical: "Baby",                                    ebay: 2984,    mercari: "baby"),
        // Pets
        .init(canonical: "Pet Supplies > Dog Supplies",             ebay: 1281,    mercari: "other"),
        .init(canonical: "Pet Supplies",                            ebay: 1281,    mercari: "other"),
        // Health & Beauty
        .init(canonical: "Health & Beauty > Skin Care",             ebay: 26395,   mercari: "beauty"),
        .init(canonical: "Health & Beauty > Vitamins",              ebay: 180959,  mercari: "beauty"),
        .init(canonical: "Health & Beauty",                         ebay: 26395,   mercari: "beauty"),
        // Musical Instruments
        .init(canonical: "Musical Instruments > Guitars",           ebay: 33034,   mercari: "other"),
        .init(canonical: "Musical Instruments",                     ebay: 619,     mercari: "other"),
        // Art
        .init(canonical: "Art > Paintings",                         ebay: 360,     mercari: "handmade"),
        .init(canonical: "Art",                                     ebay: 550,     mercari: "handmade"),
    ]

    private init() {
        // Inline cache load — actor-isolated instance methods can't be called from init in Swift 6.
        if let fetchDate = UserDefaults.standard.object(forKey: "wonni_categoryMappingsFetchDate") as? Date,
           Date().timeIntervalSince(fetchDate) < 7 * 24 * 60 * 60,
           let data = UserDefaults.standard.data(forKey: "wonni_categoryMappings"),
           let cached = try? JSONDecoder().decode([CategoryMapping].self, from: data) {
            self.mappings = cached
            self.lastFetched = fetchDate
        } else {
            self.mappings = Self.fallback
        }
    }

    /// Call at app launch or first listing — no-ops if cache is fresh.
    func fetchIfNeeded() async {
        guard lastFetched == nil || Date().timeIntervalSince(lastFetched!) >= ttl else { return }
        do {
            let doc = try await Firestore.firestore()
                .collection("system").document("categoryMappings").getDocument()
            guard let raw = doc.data()?["mappings"] as? [[String: Any]],
                  let jsonData = try? JSONSerialization.data(withJSONObject: raw),
                  let fetched = try? JSONDecoder().decode([CategoryMapping].self, from: jsonData)
            else { return }
            mappings = fetched
            lastFetched = Date()
            UserDefaults.standard.set(try? JSONEncoder().encode(fetched), forKey: udMappingsKey)
            UserDefaults.standard.set(lastFetched, forKey: udDateKey)
        } catch {
            print("[CategoryMappingRepository] Firestore fetch failed: \(error). Using fallback.")
        }
    }

    /// Best eBay category ID for a Gemini-produced category string.
    /// Pass 1: longest canonical prefix match. Pass 2: keyword overlap score.
    func bestEbayCategory(for geminiCategory: String?) -> Int {
        guard let input = geminiCategory, !input.isEmpty else { return 99 }
        let lower = input.lowercased()

        // Pass 1: prefix match (longer match = more specific)
        var prefixBest: (length: Int, id: Int)? = nil
        for m in mappings {
            let cl = m.canonical.lowercased()
            if lower.hasPrefix(cl) || cl.hasPrefix(lower) {
                let len = min(lower.count, cl.count)
                if prefixBest == nil || len > prefixBest!.length { prefixBest = (len, m.ebay) }
            }
        }
        if let best = prefixBest { return best.id }

        // Pass 2: keyword overlap
        let inputWords = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        var topScore = 0
        var topId = 99
        for m in mappings {
            let cWords = Set(m.canonical.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            let overlap = inputWords.intersection(cWords).count
            if overlap > topScore { topScore = overlap; topId = m.ebay }
        }
        return topId
    }
}
