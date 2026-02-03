/*
 Spatial Stash - Filters Tab View

 Filter and sort configuration with saved views management.
 Supports both image and video (scene) filtering based on the last viewed content tab.
 */

import SwiftUI

struct FiltersTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingSaveViewSheet = false
    @State private var newViewName = ""

    /// Whether we're filtering videos (scenes) or images
    private var isVideoFilter: Bool {
        appModel.lastContentTab == .videos
    }

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            List {
                // Context indicator
                Section {
                    HStack {
                        Image(systemName: isVideoFilter ? "video" : "photo.stack")
                            .foregroundColor(.accentColor)
                        Text("Filtering \(isVideoFilter ? "Videos" : "Pictures")")
                            .font(.headline)
                    }
                }

                // Saved Views Section
                Section {
                    if isVideoFilter {
                        // Video saved views
                        if appModel.savedVideoViews.isEmpty {
                            Text("No saved views")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(appModel.savedVideoViews) { view in
                                SavedVideoViewRow(
                                    view: view,
                                    isSelected: appModel.selectedSavedVideoView?.id == view.id,
                                    onApply: { appModel.applySavedVideoView(view) },
                                    onDeselect: { appModel.deselectVideoView() },
                                    onSetDefault: { appModel.setDefaultVideoView(view) },
                                    onClearDefault: { appModel.clearDefaultVideoView() },
                                    onDelete: { appModel.deleteSavedVideoView(view) }
                                )
                            }
                        }
                    } else {
                        // Image saved views
                        if appModel.savedViews.isEmpty {
                            Text("No saved views")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(appModel.savedViews) { view in
                                SavedViewRow(
                                    view: view,
                                    isSelected: appModel.selectedSavedView?.id == view.id,
                                    onApply: { appModel.applySavedView(view) },
                                    onDeselect: { appModel.deselectView() },
                                    onSetDefault: { appModel.setDefaultView(view) },
                                    onClearDefault: { appModel.clearDefaultView() },
                                    onDelete: { appModel.deleteSavedView(view) }
                                )
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Saved Views")
                        Spacer()
                        Button {
                            showingSaveViewSheet = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Sort Section - different fields for images vs videos
                Section("Sort") {
                    if isVideoFilter {
                        Picker("Sort By", selection: $appModel.currentVideoFilter.sortField) {
                            ForEach(SceneSortField.allCases) { field in
                                Text(field.displayName).tag(field)
                            }
                        }
                        .onChange(of: appModel.currentVideoFilter.sortField) { _, newValue in
                            appModel.resetVideoFiltersKeeping(\.sortField, value: newValue)
                            // Set random seed when Random is first selected
                            if newValue == .random && appModel.currentVideoFilter.randomSeed == nil {
                                appModel.currentVideoFilter.shuffleRandomSort()
                            }
                        }

                        Picker("Direction", selection: $appModel.currentVideoFilter.sortDirection) {
                            ForEach(SortDirection.allCases) { direction in
                                Label(direction.displayName, systemImage: direction.icon)
                                    .tag(direction)
                            }
                        }
                        .onChange(of: appModel.currentVideoFilter.sortDirection) { _, newValue in
                            appModel.resetVideoFiltersKeeping(\.sortDirection, value: newValue)
                        }

                        // Shuffle button for random sort
                        if appModel.currentVideoFilter.sortField == .random {
                            Button {
                                appModel.deselectSavedVideoViewIfNeeded()
                                appModel.currentVideoFilter.shuffleRandomSort()
                            } label: {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text("Shuffle")
                                }
                            }
                        }
                    } else {
                        Picker("Sort By", selection: $appModel.currentFilter.sortField) {
                            ForEach(ImageSortField.allCases) { field in
                                Text(field.displayName).tag(field)
                            }
                        }
                        .onChange(of: appModel.currentFilter.sortField) { _, newValue in
                            appModel.resetImageFiltersKeeping(\.sortField, value: newValue)
                            // Set random seed when Random is first selected
                            if newValue == .random && appModel.currentFilter.randomSeed == nil {
                                appModel.currentFilter.shuffleRandomSort()
                            }
                        }

                        Picker("Direction", selection: $appModel.currentFilter.sortDirection) {
                            ForEach(SortDirection.allCases) { direction in
                                Label(direction.displayName, systemImage: direction.icon)
                                    .tag(direction)
                            }
                        }
                        .onChange(of: appModel.currentFilter.sortDirection) { _, newValue in
                            appModel.resetImageFiltersKeeping(\.sortDirection, value: newValue)
                        }

                        // Shuffle button for random sort
                        if appModel.currentFilter.sortField == .random {
                            Button {
                                appModel.deselectSavedViewIfNeeded()
                                appModel.currentFilter.shuffleRandomSort()
                            } label: {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text("Shuffle")
                                }
                            }
                        }
                    }
                }

                // Search Section
                Section("Search") {
                    if isVideoFilter {
                        TextField("Search titles...", text: $appModel.currentVideoFilter.searchTerm)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .onChange(of: appModel.currentVideoFilter.searchTerm) { _, newValue in
                                appModel.resetVideoFiltersKeeping(\.searchTerm, value: newValue)
                            }
                    } else {
                        TextField("Search titles...", text: $appModel.currentFilter.searchTerm)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .onChange(of: appModel.currentFilter.searchTerm) { _, newValue in
                                appModel.resetImageFiltersKeeping(\.searchTerm, value: newValue)
                            }
                    }
                }

                // Galleries Filter
                Section("Galleries") {
                    GalleryFilterView(isVideoFilter: isVideoFilter)
                }

                // Tags Filter
                Section("Tags") {
                    TagFilterView(isVideoFilter: isVideoFilter)
                }

                // O Count Filter
                Section("O Count") {
                    OCountFilterView(isVideoFilter: isVideoFilter)
                }

                // Rating Filter
                Section("Rating") {
                    RatingFilterView(isVideoFilter: isVideoFilter)
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
            .navigationTitle(isVideoFilter ? "Video Filters" : "Picture Filters")
            .task {
                await appModel.loadAutocompleteData()
            }
            .onDisappear {
                // Only reload if no saved view is selected (user manually changed filters)
                // If a saved view is selected, it was already applied when selected
                Task {
                    if isVideoFilter {
                        if appModel.selectedSavedVideoView == nil {
                            await appModel.applyVideoFilter()
                        }
                    } else {
                        if appModel.selectedSavedView == nil {
                            await appModel.applyFilter()
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSaveViewSheet) {
                SaveViewSheet(viewName: $newViewName) {
                    if !newViewName.isEmpty {
                        if isVideoFilter {
                            appModel.createSavedVideoView(name: newViewName)
                        } else {
                            appModel.createSavedView(name: newViewName)
                        }
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
    let onApply: () -> Void
    let onDeselect: () -> Void
    let onSetDefault: () -> Void
    let onClearDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isSelected {
                    onDeselect()
                } else {
                    onApply()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(view.name)
                                .font(.headline)
                            if view.isDefault {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                            }
                        }
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if view.isDefault {
                    Button {
                        onClearDefault()
                    } label: {
                        Label("Remove as Default", systemImage: "star.slash")
                    }
                } else {
                    Button {
                        onSetDefault()
                    } label: {
                        Label("Set as Default", systemImage: "star")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
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

// MARK: - Saved Video View Row

struct SavedVideoViewRow: View {
    let view: SavedVideoView
    let isSelected: Bool
    let onApply: () -> Void
    let onDeselect: () -> Void
    let onSetDefault: () -> Void
    let onClearDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isSelected {
                    onDeselect()
                } else {
                    onApply()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(view.name)
                                .font(.headline)
                            if view.isDefault {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                            }
                        }
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if view.isDefault {
                    Button {
                        onClearDefault()
                    } label: {
                        Label("Remove as Default", systemImage: "star.slash")
                    }
                } else {
                    Button {
                        onSetDefault()
                    } label: {
                        Label("Set as Default", systemImage: "star")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
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
    let isVideoFilter: Bool

    private var selectedGalleries: [AutocompleteItem] {
        isVideoFilter ? appModel.currentVideoFilter.selectedGalleries : appModel.currentFilter.selectedGalleries
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            // Modifier picker
            if isVideoFilter {
                Picker("Match", selection: $appModel.currentVideoFilter.galleryModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appModel.currentVideoFilter.galleryModifier) { _, newValue in
                    appModel.resetVideoFiltersKeeping(\.galleryModifier, value: newValue)
                }
            } else {
                Picker("Match", selection: $appModel.currentFilter.galleryModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appModel.currentFilter.galleryModifier) { _, newValue in
                    appModel.resetImageFiltersKeeping(\.galleryModifier, value: newValue)
                }
            }

            // Search field
            TextField("Search galleries...", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task {
                        await appModel.searchGalleries(query: newValue)
                    }
                }

            // Selected galleries
            if !selectedGalleries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(selectedGalleries) { gallery in
                            SelectedItemChip(name: gallery.name) {
                                if isVideoFilter {
                                    appModel.deselectSavedVideoViewIfNeeded()
                                    appModel.currentVideoFilter.selectedGalleries.removeAll { $0.id == gallery.id }
                                } else {
                                    appModel.deselectSavedViewIfNeeded()
                                    appModel.currentFilter.selectedGalleries.removeAll { $0.id == gallery.id }
                                }
                            }
                        }
                    }
                }
            }

            // Available galleries
            if appModel.isLoadingGalleries {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                let selectedIds = Set(selectedGalleries.map { $0.id })
                let availableToSelect = appModel.availableGalleries.filter { !selectedIds.contains($0.id) }
                if !availableToSelect.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availableToSelect) { gallery in
                                Button {
                                    if isVideoFilter {
                                        appModel.deselectSavedVideoViewIfNeeded()
                                        appModel.currentVideoFilter.selectedGalleries.append(gallery)
                                    } else {
                                        appModel.deselectSavedViewIfNeeded()
                                        appModel.currentFilter.selectedGalleries.append(gallery)
                                    }
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
    let isVideoFilter: Bool

    private var selectedTags: [AutocompleteItem] {
        isVideoFilter ? appModel.currentVideoFilter.selectedTags : appModel.currentFilter.selectedTags
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            // Modifier picker
            if isVideoFilter {
                Picker("Match", selection: $appModel.currentVideoFilter.tagModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appModel.currentVideoFilter.tagModifier) { _, newValue in
                    appModel.resetVideoFiltersKeeping(\.tagModifier, value: newValue)
                }
            } else {
                Picker("Match", selection: $appModel.currentFilter.tagModifier) {
                    ForEach(CriterionModifier.multiModifiers) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appModel.currentFilter.tagModifier) { _, newValue in
                    appModel.resetImageFiltersKeeping(\.tagModifier, value: newValue)
                }
            }

            // Search field
            TextField("Search tags...", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    Task {
                        await appModel.searchTags(query: newValue)
                    }
                }

            // Selected tags
            if !selectedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(selectedTags) { tag in
                            SelectedItemChip(name: tag.name) {
                                if isVideoFilter {
                                    appModel.deselectSavedVideoViewIfNeeded()
                                    appModel.currentVideoFilter.selectedTags.removeAll { $0.id == tag.id }
                                } else {
                                    appModel.deselectSavedViewIfNeeded()
                                    appModel.currentFilter.selectedTags.removeAll { $0.id == tag.id }
                                }
                            }
                        }
                    }
                }
            }

            // Available tags
            if appModel.isLoadingTags {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                let selectedIds = Set(selectedTags.map { $0.id })
                let availableToSelect = appModel.availableTags.filter { !selectedIds.contains($0.id) }
                if !availableToSelect.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availableToSelect) { tag in
                                Button {
                                    if isVideoFilter {
                                        appModel.deselectSavedVideoViewIfNeeded()
                                        appModel.currentVideoFilter.selectedTags.append(tag)
                                    } else {
                                        appModel.deselectSavedViewIfNeeded()
                                        appModel.currentFilter.selectedTags.append(tag)
                                    }
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
    let isVideoFilter: Bool

    private var oCountEnabled: Bool {
        isVideoFilter ? appModel.currentVideoFilter.oCountEnabled : appModel.currentFilter.oCountEnabled
    }

    private var oCountModifier: CriterionModifier {
        isVideoFilter ? appModel.currentVideoFilter.oCountModifier : appModel.currentFilter.oCountModifier
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            if isVideoFilter {
                Toggle("Enable Filter", isOn: $appModel.currentVideoFilter.oCountEnabled)
                    .onChange(of: appModel.currentVideoFilter.oCountEnabled) { _, newValue in
                        appModel.resetVideoFiltersKeeping(\.oCountEnabled, value: newValue)
                    }
            } else {
                Toggle("Enable Filter", isOn: $appModel.currentFilter.oCountEnabled)
                    .onChange(of: appModel.currentFilter.oCountEnabled) { _, newValue in
                        appModel.resetImageFiltersKeeping(\.oCountEnabled, value: newValue)
                    }
            }

            if oCountEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Condition")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if isVideoFilter {
                        Picker("Condition", selection: $appModel.currentVideoFilter.oCountModifier) {
                            ForEach(CriterionModifier.numberModifiers) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: appModel.currentVideoFilter.oCountModifier) { _, newValue in
                            appModel.resetVideoFiltersKeeping(\.oCountModifier, value: newValue)
                        }
                    } else {
                        Picker("Condition", selection: $appModel.currentFilter.oCountModifier) {
                            ForEach(CriterionModifier.numberModifiers) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: appModel.currentFilter.oCountModifier) { _, newValue in
                            appModel.resetImageFiltersKeeping(\.oCountModifier, value: newValue)
                        }
                    }
                }

                if oCountModifier.requiresRange {
                    HStack {
                        if isVideoFilter {
                            TextField("Min", value: $appModel.currentVideoFilter.oCountRange.min, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onChange(of: appModel.currentVideoFilter.oCountRange.min) { _, newValue in
                                    appModel.resetVideoFiltersKeeping(\.oCountRange.min, value: newValue)
                                }
                            Text("to")
                            TextField("Max", value: $appModel.currentVideoFilter.oCountRange.max, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onChange(of: appModel.currentVideoFilter.oCountRange.max) { _, newValue in
                                    appModel.resetVideoFiltersKeeping(\.oCountRange.max, value: newValue)
                                }
                        } else {
                            TextField("Min", value: $appModel.currentFilter.oCountRange.min, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onChange(of: appModel.currentFilter.oCountRange.min) { _, newValue in
                                    appModel.resetImageFiltersKeeping(\.oCountRange.min, value: newValue)
                                }
                            Text("to")
                            TextField("Max", value: $appModel.currentFilter.oCountRange.max, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onChange(of: appModel.currentFilter.oCountRange.max) { _, newValue in
                                    appModel.resetImageFiltersKeeping(\.oCountRange.max, value: newValue)
                                }
                        }
                    }
                } else if oCountModifier.requiresValue {
                    if isVideoFilter {
                        TextField("Value", value: $appModel.currentVideoFilter.oCountValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .onChange(of: appModel.currentVideoFilter.oCountValue) { _, newValue in
                                appModel.resetVideoFiltersKeeping(\.oCountValue, value: newValue)
                            }
                    } else {
                        TextField("Value", value: $appModel.currentFilter.oCountValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .onChange(of: appModel.currentFilter.oCountValue) { _, newValue in
                                appModel.resetImageFiltersKeeping(\.oCountValue, value: newValue)
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Rating Filter View

struct RatingFilterView: View {
    @Environment(AppModel.self) private var appModel
    let isVideoFilter: Bool

    private var ratingEnabled: Bool {
        isVideoFilter ? appModel.currentVideoFilter.ratingEnabled : appModel.currentFilter.ratingEnabled
    }

    private var ratingModifier: CriterionModifier {
        isVideoFilter ? appModel.currentVideoFilter.ratingModifier : appModel.currentFilter.ratingModifier
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 12) {
            if isVideoFilter {
                Toggle("Enable Filter", isOn: $appModel.currentVideoFilter.ratingEnabled)
                    .onChange(of: appModel.currentVideoFilter.ratingEnabled) { _, newValue in
                        appModel.resetVideoFiltersKeeping(\.ratingEnabled, value: newValue)
                    }
            } else {
                Toggle("Enable Filter", isOn: $appModel.currentFilter.ratingEnabled)
                    .onChange(of: appModel.currentFilter.ratingEnabled) { _, newValue in
                        appModel.resetImageFiltersKeeping(\.ratingEnabled, value: newValue)
                    }
            }

            if ratingEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Condition")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if isVideoFilter {
                        Picker("Condition", selection: $appModel.currentVideoFilter.ratingModifier) {
                            ForEach(CriterionModifier.numberModifiers) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: appModel.currentVideoFilter.ratingModifier) { _, newValue in
                            appModel.resetVideoFiltersKeeping(\.ratingModifier, value: newValue)
                        }
                    } else {
                        Picker("Condition", selection: $appModel.currentFilter.ratingModifier) {
                            ForEach(CriterionModifier.numberModifiers) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: appModel.currentFilter.ratingModifier) { _, newValue in
                            appModel.resetImageFiltersKeeping(\.ratingModifier, value: newValue)
                        }
                    }
                }

                if ratingModifier.requiresRange {
                    if isVideoFilter {
                        HStack {
                            Text("Min:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentVideoFilter.ratingRange.min ?? 1 },
                                set: {
                                    appModel.deselectSavedVideoViewIfNeeded()
                                    appModel.currentVideoFilter.ratingRange.min = $0
                                }
                            ))
                        }
                        HStack {
                            Text("Max:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentVideoFilter.ratingRange.max ?? 5 },
                                set: {
                                    appModel.deselectSavedVideoViewIfNeeded()
                                    appModel.currentVideoFilter.ratingRange.max = $0
                                }
                            ))
                        }
                    } else {
                        HStack {
                            Text("Min:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentFilter.ratingRange.min ?? 1 },
                                set: {
                                    appModel.deselectSavedViewIfNeeded()
                                    appModel.currentFilter.ratingRange.min = $0
                                }
                            ))
                        }
                        HStack {
                            Text("Max:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentFilter.ratingRange.max ?? 5 },
                                set: {
                                    appModel.deselectSavedViewIfNeeded()
                                    appModel.currentFilter.ratingRange.max = $0
                                }
                            ))
                        }
                    }
                } else if ratingModifier.requiresValue {
                    if isVideoFilter {
                        HStack {
                            Text("Rating:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentVideoFilter.ratingValue ?? 3 },
                                set: {
                                    appModel.deselectSavedVideoViewIfNeeded()
                                    appModel.currentVideoFilter.ratingValue = $0
                                }
                            ))
                        }
                    } else {
                        HStack {
                            Text("Rating:")
                            StarRatingPicker(rating: Binding(
                                get: { appModel.currentFilter.ratingValue ?? 3 },
                                set: {
                                    appModel.deselectSavedViewIfNeeded()
                                    appModel.currentFilter.ratingValue = $0
                                }
                            ))
                        }
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
