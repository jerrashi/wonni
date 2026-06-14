//
//  ListingTemplatesView.swift
//  wonni
//

import SwiftUI
import PhotosUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// MARK: - Templates List (settings page)

struct ListingTemplatesView: View {
    @StateObject private var repo = ListingTemplateRepository.shared
    @State private var showNewTemplate = false
    @State private var editingTemplate: ListingTemplate?

    var body: some View {
        List {
            if repo.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if repo.templates.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No Templates Yet")
                        .font(.title3.weight(.semibold))
                    Text("Create reusable templates to pre-fill titles, descriptions, shipping, platforms, and photos.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Create Template") { showNewTemplate = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding().listRowBackground(Color.clear)
            } else {
                ForEach(repo.templates) { template in
                    Button { editingTemplate = template } label: {
                        TemplateRowView(template: template)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        let t = repo.templates[idx]
                        Task { await repo.delete(t) }
                    }
                }
            }
        }
        .navigationTitle("Listing Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewTemplate = true } label: { Image(systemName: "plus") }
            }
            if !repo.templates.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
            }
        }
        .sheet(isPresented: $showNewTemplate) {
            EditTemplateSheet(template: nil, onSave: { _ in })
        }
        .sheet(item: $editingTemplate) { template in
            EditTemplateSheet(template: template, onSave: { _ in })
        }
        .task { await repo.loadTemplates() }
    }
}

// MARK: - Template Row

struct TemplateRowView: View {
    let template: ListingTemplate

    var body: some View {
        HStack(spacing: 12) {
            if let path = template.photoPaths.first {
                StorageImage(path: path)
                    .frame(width: 44, height: 44).cornerRadius(6)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.systemGray5))
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
                .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name).font(.subheadline.weight(.semibold))
                Text(templateSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var templateSummary: String {
        var parts: [String] = []
        if template.title != nil { parts.append("Title") }
        if template.customDescription != nil { parts.append("Description") }
        if template.condition != nil { parts.append("Condition") }
        if template.isFreeShipping != nil { parts.append("Shipping") }
        if let p = template.platforms, !p.isEmpty { parts.append(p.map { $0.capitalized }.joined(separator: "/")) }
        if !template.photoPaths.isEmpty { parts.append("\(template.photoPaths.count) photo\(template.photoPaths.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "No fields set" : parts.joined(separator: " · ")
    }
}

// MARK: - Edit/Create Template Sheet

struct EditTemplateSheet: View {
    let existingTemplate: ListingTemplate?
    let onSave: (ListingTemplate) -> Void

    @StateObject private var repo = ListingTemplateRepository.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var title: String
    @State private var description: String
    @State private var condition: ItemCondition?
    @State private var brand: String
    @State private var category: String

    @State private var hasShipping: Bool
    @State private var isFreeShipping: Bool
    @State private var weightLbs: Double?
    @State private var lengthIn: Double?
    @State private var widthIn: Double?
    @State private var heightIn: Double?

    @State private var selectedPlatforms: Set<String>

    @State private var editPhotos: [EditPhotoItem]
    @State private var newPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoEditModal = false

    @State private var isSaving = false
    @State private var saveError: String?

    private let templateId: String

    init(template: ListingTemplate?, onSave: @escaping (ListingTemplate) -> Void) {
        self.existingTemplate = template
        self.onSave = onSave
        self.templateId = template?.id ?? UUID().uuidString

        _name = State(initialValue: template?.name ?? "")
        _title = State(initialValue: template?.title ?? "")
        _description = State(initialValue: template?.customDescription ?? "")
        _condition = State(initialValue: template?.condition.flatMap { ItemCondition(rawValue: $0) })
        _brand = State(initialValue: template?.brand ?? "")
        _category = State(initialValue: template?.category ?? "")
        _hasShipping = State(initialValue: template?.isFreeShipping != nil || template?.weightLbs != nil || template?.packageDimensions != nil)
        _isFreeShipping = State(initialValue: template?.isFreeShipping ?? false)
        _weightLbs = State(initialValue: template?.weightLbs)
        _lengthIn = State(initialValue: template?.packageDimensions?.lengthIn)
        _widthIn = State(initialValue: template?.packageDimensions?.widthIn)
        _heightIn = State(initialValue: template?.packageDimensions?.heightIn)
        _selectedPlatforms = State(initialValue: Set(template?.platforms ?? []))
        _editPhotos = State(initialValue: (template?.photoPaths ?? []).map { .existing(path: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template Name") {
                    TextField("e.g. K-pop CD, Clothing S/M", text: $name)
                }

                Section("Photos") {
                    HStack {
                        Spacer()
                        if !editPhotos.isEmpty {
                            Button {
                                showPhotoEditModal = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.blue)
                                    .padding(6)
                                    .background(Color.blue.opacity(0.1))
                                    .clipShape(Circle())
                            }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(editPhotos) { item in
                                photoTile(item)
                            }
                            PhotosPicker(selection: $newPhotoItems, matching: .images) {
                                VStack(spacing: 4) {
                                    Image(systemName: "plus.circle").font(.title2)
                                    Text("Add").font(.caption2)
                                }
                                .foregroundColor(.accentColor)
                                .frame(width: 80, height: 80)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                            }
                            .onChange(of: newPhotoItems) { _, items in
                                Task {
                                    for item in items {
                                        if let data = try? await item.loadTransferable(type: Data.self),
                                           let img = UIImage(data: data) {
                                            editPhotos.append(.new(id: UUID().uuidString, image: img))
                                        }
                                    }
                                    newPhotoItems = []
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Listing Fields") {
                    TextField("Title (optional)", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    Picker("Condition", selection: $condition) {
                        Text("Not set").tag(ItemCondition?.none)
                        ForEach(ItemCondition.allCases, id: \.self) { c in
                            Text(c.displayName).tag(ItemCondition?.some(c))
                        }
                    }
                    TextField("Brand", text: $brand)
                    TextField("Category", text: $category)
                }

                Section("Shipping") {
                    Toggle("Include shipping settings", isOn: $hasShipping.animation())
                    if hasShipping {
                        Toggle("Free shipping (buyer doesn't pay)", isOn: $isFreeShipping)
                        HStack {
                            Text("Weight (lbs)")
                            Spacer()
                            TextField("0.0", value: $weightLbs, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                        }
                        HStack(spacing: 8) {
                            Text("L")
                            TextField("0", value: $lengthIn, format: .number)
                                .keyboardType(.decimalPad).frame(maxWidth: 50)
                            Text("W")
                            TextField("0", value: $widthIn, format: .number)
                                .keyboardType(.decimalPad).frame(maxWidth: 50)
                            Text("H (in)")
                            TextField("0", value: $heightIn, format: .number)
                                .keyboardType(.decimalPad).frame(maxWidth: 50)
                        }
                    }
                }

                Section("Platforms") {
                    ForEach(["mercari", "ebay", "etsy", "facebook"], id: \.self) { platform in
                        Toggle(platformName(platform), isOn: Binding(
                            get: { selectedPlatforms.contains(platform) },
                            set: { on in
                                if on { selectedPlatforms.insert(platform) }
                                else { selectedPlatforms.remove(platform) }
                            }
                        ))
                    }
                }

                if let err = saveError {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(existingTemplate == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await saveTemplate() }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showPhotoEditModal) {
            PublishedPhotoModal(photos: $editPhotos)
        }
    }

    @ViewBuilder
    private func photoTile(_ item: EditPhotoItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch item {
                case .existing(let path): StorageImage(path: path)
                case .new(_, let img): Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .frame(width: 80, height: 80)
            .cornerRadius(8)
            .clipped()
        }
    }

    private func platformName(_ platform: String) -> String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari"
        case "facebook": return "Facebook Marketplace"
        default: return platform.capitalized
        }
    }

    private func saveTemplate() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        var finalPaths: [String] = []
        for item in editPhotos {
            switch item {
            case .existing(let path):
                finalPaths.append(path)
            case .new(_, let img):
                if let path = try? await StorageService.shared.uploadTemplateImage(
                    image: img, index: finalPaths.count, userId: uid, templateId: templateId
                ) {
                    finalPaths.append(path)
                }
            }
        }

        var dims: PackageDimensions? = nil
        if hasShipping, let l = lengthIn, let w = widthIn, let h = heightIn {
            dims = PackageDimensions(lengthIn: l, widthIn: w, heightIn: h)
        }

        let template = ListingTemplate(
            id: existingTemplate?.id ?? templateId,
            name: name.trimmingCharacters(in: .whitespaces),
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title.trimmingCharacters(in: .whitespaces),
            customDescription: description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description.trimmingCharacters(in: .whitespaces),
            condition: condition?.rawValue,
            brand: brand.trimmingCharacters(in: .whitespaces).isEmpty ? nil : brand.trimmingCharacters(in: .whitespaces),
            category: category.trimmingCharacters(in: .whitespaces).isEmpty ? nil : category.trimmingCharacters(in: .whitespaces),
            isFreeShipping: hasShipping ? isFreeShipping : nil,
            weightLbs: hasShipping ? weightLbs : nil,
            packageDimensions: hasShipping ? dims : nil,
            platforms: selectedPlatforms.isEmpty ? nil : Array(selectedPlatforms).sorted(),
            photoPaths: finalPaths,
            createdAt: existingTemplate?.createdAt ?? Timestamp(date: Date())
        )

        do {
            try await ListingTemplateRepository.shared.save(template)
            onSave(template)
            dismiss()
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Template Picker Sheet

struct TemplatePickerSheet: View {
    let onApply: (ListingTemplate) -> Void

    @StateObject private var repo = ListingTemplateRepository.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showNewTemplate = false

    var body: some View {
        NavigationStack {
            Group {
                if repo.isLoading {
                    ProgressView("Loading templates…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if repo.templates.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("No Templates Yet")
                            .font(.title3.weight(.semibold))
                        Text("Create a template to quickly fill common listing fields.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Create Template") { showNewTemplate = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    List(repo.templates) { template in
                        Button {
                            onApply(template)
                            dismiss()
                        } label: {
                            TemplateRowView(template: template)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Apply Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewTemplate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showNewTemplate) {
                EditTemplateSheet(template: nil, onSave: { _ in })
            }
        }
        .task { await repo.loadTemplates() }
    }
}
