/*
 Spatial Stash - Filters Tab View

 Filter and sort configuration with saved views management.
 */

import SwiftUI

struct FiltersTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingSaveViewSheet = false
    @State private var newViewName = ""

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            List {
                // Saved Views Section
                Section("Saved Views") {
                    if appModel.savedViews.isEmpty {
                        Text("No saved views")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(appModel.savedViews) { view in
                            SavedViewRow(view: view, isSelected: appModel.selectedSavedView?.id == view.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appModel.applySavedView(view)
                                }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                appModel.deleteSavedView(appModel.savedViews[index])
                            }
                        }
                    }

                    Button {
                        showingSaveViewSheet = true
                    } label: {
                        Label("Save Current View", systemImage: "plus.circle")
                    }
                }

                // Sort Section
                Section("Sort") {
                    Picker("Sort By", selection: $appModel.currentFilter.sortField) {
                        ForEach(ImageSortField.allCases) { field in
                            Text(field.displayName).tag(field)
                        }
                    }

                    Picker("Direction", selection: $appModel.currentFilter.sortDirection) {
                        ForEach(SortDirection.allCases) { direction in
                            Label(direction.displayName, systemImage: direction.icon)
                                .tag(direction)
                        }
                    }
                }

                // Search Section
                Section("Search") {
                    TextField("Search titles...", text: $appModel.currentFilter.searchTerm)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                }

                // Galleries Filter
                Section("Galleries") {
                    GalleryFilterView()
                }

                // Tags Filter
                Section("Tags") {
                    TagFilterView()
                }

                // O Count Filter
                Section("O Count") {
                    OCountFilterView()
                }

                // Rating Filter
                Section("Rating") {
                    RatingFilterView()
                }

                // Actions Section
                Section {
                    Button {
                        Task {
                            await appModel.applyFilter()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Label("Apply Filters", systemImage: "checkmark.circle")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(appModel.mediaSourceType != .stashServer)

                    if appModel.currentFilter.hasActiveFilters {
                        Button(role: .destructive) {
                            Task {
                                await appModel.clearFilters()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Label("Clear All Filters", systemImage: "xmark.circle")
                                Spacer()
                            }
                        }
                    }
                }

                // Info Section
                if appModel.mediaSourceType != .stashServer {
                    Section {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.orange)
                            Text("Filters only work with Stash Server. Switch to Stash Server in Settings.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .task {
                await appModel.loadAutocompleteData()
            }
            .sheet(isPresented: $showingSaveViewSheet) {
                SaveViewSheet(viewName: $newViewName) {
                    if !newViewName.isEmpty {
                        appModel.createSavedView(name: newViewName)
                        newViewName = ""
                    }
                    showingSaveViewSheet = false
                }
            }
        }
    }
}

// MARK: - Saved View Row

struct SavedViewRow: View {
    let view: SavedView
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(view.name)
                    .font(.headline)
                Text(filterSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !view.filter.searchTerm.isEmpty {
            parts.append("Search: \(view.filter.searchTerm)")
        }
        if !view.filter.selectedTags.isEmpty {
            parts.append("\(view.filter.selectedTags.count) tags")
        }
        if !view.filter.selectedGalleries.isEmpty {
            parts.append("\(view.filter.selectedGalleries.count) galleries")
        }
        if view.filter.ratingEnabled {
            parts.append("Rating filter")
        }
        if view.filter.oCountEnabled {
            parts.append("O Count filter")
        }
        parts.append("\(view.filter.sortField.displayName) \(view.filter.sortDirection.displayName)")
        return parts.joined(separator: " | ")
    }
}

// MARK: - Save View Sheet

struct SaveViewSheet: View {
    @Binding var viewName: String
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("View Name", text: $viewName)
                    .textFieldStyle(.plain)
            }
            .navigationTitle("Save View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewName = ""
                        onSave()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                    }
                    .disabled(viewName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Gallery Filter View

struct GalleryFilterView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            // Modifier picker
            Picker("Match", selection: $appModel.currentFilter.galleryModifier) {
                ForEach(CriterionModifier.multiModifiers) { modifier in
                    Text(modifier.displayName).tag(modifier)
                }
            }
            .pickerStyle(.menu)

            // Search field
            TextField("Search galleries...", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task {
                        await appModel.searchGalleries(query: newValue)
                    }
                }

            // Selected galleries - now using selectedGalleries which stores full items
            if !appModel.currentFilter.selectedGalleries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(appModel.currentFilter.selectedGalleries) { gallery in
                            SelectedItemChip(name: gallery.name) {
                                appModel.currentFilter.selectedGalleries.removeAll { $0.id == gallery.id }
                            }
                        }
                    }
                }
            }

            // Available galleries
            if appModel.isLoadingGalleries {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if !appModel.availableGalleries.isEmpty {
                let selectedIds = Set(appModel.currentFilter.selectedGalleries.map { $0.id })
                let availableToSelect = appModel.availableGalleries.filter { !selectedIds.contains($0.id) }
                if !availableToSelect.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availableToSelect) { gallery in
                                Button {
                                    appModel.currentFilter.selectedGalleries.append(gallery)
                                } label: {
                                    Text(gallery.name)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tag Filter View

struct TagFilterView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            // Modifier picker
            Picker("Match", selection: $appModel.currentFilter.tagModifier) {
                ForEach(CriterionModifier.multiModifiers) { modifier in
                    Text(modifier.displayName).tag(modifier)
                }
            }
            .pickerStyle(.menu)

            // Search field
            TextField("Search tags...", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task {
                        await appModel.searchTags(query: newValue)
                    }
                }

            // Selected tags - now using selectedTags which stores full items
            if !appModel.currentFilter.selectedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(appModel.currentFilter.selectedTags) { tag in
                            SelectedItemChip(name: tag.name) {
                                appModel.currentFilter.selectedTags.removeAll { $0.id == tag.id }
                            }
                        }
                    }
                }
            }

            // Available tags
            if appModel.isLoadingTags {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if !appModel.availableTags.isEmpty {
                let selectedIds = Set(appModel.currentFilter.selectedTags.map { $0.id })
                let availableToSelect = appModel.availableTags.filter { !selectedIds.contains($0.id) }
                if !availableToSelect.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availableToSelect) { tag in
                                Button {
                                    appModel.currentFilter.selectedTags.append(tag)
                                } label: {
                                    Text(tag.name)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Selected Item Chip

struct SelectedItemChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.2))
        .cornerRadius(8)
    }
}

// MARK: - O Count Filter View

struct OCountFilterView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Filter", isOn: $appModel.currentFilter.oCountEnabled)

            if appModel.currentFilter.oCountEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Condition")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Picker("Condition", selection: $appModel.currentFilter.oCountModifier) {
                        ForEach(CriterionModifier.numberModifiers) { modifier in
                            Text(modifier.displayName).tag(modifier)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if appModel.currentFilter.oCountModifier.requiresRange {
                    HStack {
                        TextField("Min", value: $appModel.currentFilter.oCountRange.min, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("to")
                        TextField("Max", value: $appModel.currentFilter.oCountRange.max, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                } else if appModel.currentFilter.oCountModifier.requiresValue {
                    TextField("Value", value: $appModel.currentFilter.oCountValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
        }
    }
}

// MARK: - Rating Filter View

struct RatingFilterView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Filter", isOn: $appModel.currentFilter.ratingEnabled)

            if appModel.currentFilter.ratingEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Condition")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Picker("Condition", selection: $appModel.currentFilter.ratingModifier) {
                        ForEach(CriterionModifier.numberModifiers) { modifier in
                            Text(modifier.displayName).tag(modifier)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if appModel.currentFilter.ratingModifier.requiresRange {
                    HStack {
                        Text("Min:")
                        StarRatingPicker(rating: Binding(
                            get: { appModel.currentFilter.ratingRange.min ?? 1 },
                            set: { appModel.currentFilter.ratingRange.min = $0 }
                        ))
                    }
                    HStack {
                        Text("Max:")
                        StarRatingPicker(rating: Binding(
                            get: { appModel.currentFilter.ratingRange.max ?? 5 },
                            set: { appModel.currentFilter.ratingRange.max = $0 }
                        ))
                    }
                } else if appModel.currentFilter.ratingModifier.requiresValue {
                    HStack {
                        Text("Rating:")
                        StarRatingPicker(rating: Binding(
                            get: { appModel.currentFilter.ratingValue ?? 3 },
                            set: { appModel.currentFilter.ratingValue = $0 }
                        ))
                    }
                }
            }
        }
    }
}

// MARK: - Star Rating Picker

struct StarRatingPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundColor(star <= rating ? .yellow : .gray)
                    .onTapGesture {
                        rating = star
                    }
            }
        }
    }
}
