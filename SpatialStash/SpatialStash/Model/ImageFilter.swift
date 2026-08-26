/*
 Spatial Stash - Image Filter Model

 Defines filter criteria, modifiers, and saved views for image filtering.
 */

import Foundation

// MARK: - Criterion Modifier

/// Operators for filter criteria (matches Stash CriterionModifier enum)
enum CriterionModifier: String, CaseIterable, Identifiable, Codable {
    case equals = "EQUALS"
    case notEquals = "NOT_EQUALS"
    case greaterThan = "GREATER_THAN"
    case lessThan = "LESS_THAN"
    case isNull = "IS_NULL"
    case notNull = "NOT_NULL"
    case between = "BETWEEN"
    case notBetween = "NOT_BETWEEN"
    case includes = "INCLUDES"
    case includesAll = "INCLUDES_ALL"
    case excludes = "EXCLUDES"

    var id: String { rawValue }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .equals: return "is"
        case .notEquals: return "is not"
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .isNull: return "is null"
        case .notNull: return "is not null"
        case .between: return "between"
        case .notBetween: return "not between"
        case .includes: return "includes"
        case .includesAll: return "includes all"
        case .excludes: return "excludes"
        }
    }

    /// Modifiers valid for number criteria
    static var numberModifiers: [CriterionModifier] {
        [.equals, .notEquals, .greaterThan, .lessThan, .between, .notBetween, .isNull, .notNull]
    }

    /// Modifiers valid for multi-select criteria (tags, galleries)
    static var multiModifiers: [CriterionModifier] {
        [.includesAll, .includes, .excludes]
    }

    /// Whether this modifier requires a value
    var requiresValue: Bool {
        switch self {
        case .isNull, .notNull:
            return false
        default:
            return true
        }
    }

    /// Whether this modifier requires a range (two values)
    var requiresRange: Bool {
        switch self {
        case .between, .notBetween:
            return true
        default:
            return false
        }
    }
}

// MARK: - Sort Direction

enum SortDirection: String, CaseIterable, Identifiable, Codable {
    case ascending = "ASC"
    case descending = "DESC"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }

    var icon: String {
        switch self {
        case .ascending: return "arrow.up"
        case .descending: return "arrow.down"
        }
    }
}

// MARK: - Sort Field

enum ImageSortField: String, CaseIterable, Identifiable, Codable {
    case path = "path"
    case rating = "rating"
    case oCount = "o_count"
    case filesize = "filesize"
    case date = "date"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case random = "random"
    case title = "title"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .path: return "Path"
        case .rating: return "Rating"
        case .oCount: return "O Count"
        case .filesize: return "File Size"
        case .date: return "Date"
        case .createdAt: return "Created At"
        case .updatedAt: return "Updated At"
        case .random: return "Random"
        case .title: return "Title"
        }
    }
}

// MARK: - Scene Sort Field

enum SceneSortField: String, CaseIterable, Identifiable, Codable {
    case date = "date"
    case title = "title"
    case rating = "rating"
    case oCount = "o_count"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case filesize = "filesize"
    case duration = "duration"
    case framerate = "framerate"
    case bitrate = "bitrate"
    case playCount = "play_count"
    case lastPlayedAt = "last_played_at"
    case random = "random"
    case path = "path"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .date: return "Date"
        case .title: return "Title"
        case .rating: return "Rating"
        case .oCount: return "O Count"
        case .createdAt: return "Created At"
        case .updatedAt: return "Updated At"
        case .filesize: return "File Size"
        case .duration: return "Duration"
        case .framerate: return "Framerate"
        case .bitrate: return "Bitrate"
        case .playCount: return "Play Count"
        case .lastPlayedAt: return "Last Played"
        case .random: return "Random"
        case .path: return "Path"
        }
    }
}

// MARK: - Number Range

struct NumberRange: Codable, Equatable {
    var min: Int?
    var max: Int?

    var isEmpty: Bool {
        min == nil && max == nil
    }
}

// MARK: - Filter Criteria

/// Represents a filter for image queries
struct ImageFilterCriteria: Codable, Equatable {
    // Search term (matches title)
    var searchTerm: String = ""

    // Gallery filter - stores full items with names for display
    var selectedGalleries: [AutocompleteItem] = []
    var galleryModifier: CriterionModifier = .includesAll

    // O Count filter
    var oCountEnabled: Bool = false
    var oCountModifier: CriterionModifier = .equals
    var oCountValue: Int?
    var oCountRange: NumberRange = NumberRange()

    // Rating filter (rating100 in Stash, 1-100)
    var ratingEnabled: Bool = false
    var ratingModifier: CriterionModifier = .equals
    var ratingValue: Int?  // 1-5 stars, converted to 1-100 for API
    var ratingRange: NumberRange = NumberRange()  // Also 1-5 stars

    // Tags filter - stores full items with names for display
    var selectedTags: [AutocompleteItem] = []
    var tagModifier: CriterionModifier = .includesAll

    // Studios filter
    var selectedStudios: [AutocompleteItem] = []
    var studioModifier: CriterionModifier = .includesAll

    // Performers filter
    var selectedPerformers: [AutocompleteItem] = []
    var performerModifier: CriterionModifier = .includesAll

    /// Only items this app has already produced 3D output for.
    ///
    /// Lives here rather than in the photo-library criteria because it is the one
    /// dimension that means exactly the same thing in both libraries, and it is
    /// answered the same way in both: `ConvertedMediaRegistry` resolves the
    /// identities, and each source applies them however it can.
    ///
    /// Optional, not a defaulted Bool: the synthesized decoder calls `decode`
    /// for a non-optional even when it has a default, so adding one would have
    /// thrown on every saved view written before this — and the whole array
    /// decodes under one `try?`.
    var onlyConverted: Bool?

    /// `onlyConverted` as a plain Bool, so a Toggle can bind to it.
    var showsOnlyConverted: Bool {
        get { onlyConverted ?? false }
        set { onlyConverted = newValue }
    }

    // Photo-library criteria. Read only when the library in force is Photos —
    // the Stash fields above and these describe two different data models, and
    // the Filters tab shows whichever set belongs to the library being browsed.
    // Optional, not defaulted: see PhotosFilterCriteria for why that matters to
    // saved views written before it existed.
    var photos: PhotosFilterCriteria?

    /// The photo-library half as a non-optional, so SwiftUI can bind straight
    /// into its fields.
    var photosCriteria: PhotosFilterCriteria {
        get { photos ?? PhotosFilterCriteria() }
        set { photos = newValue }
    }

    // Sort options
    var sortField: ImageSortField = .createdAt
    var sortDirection: SortDirection = .descending
    var randomSeed: Int? = nil  // Random seed for consistent pagination when sorting by random

    /// Get gallery IDs for API queries
    var galleryIds: [String] {
        selectedGalleries.map { $0.id }
    }

    /// Get tag IDs for API queries
    var tagIds: [String] {
        selectedTags.map { $0.id }
    }

    /// Get studio IDs for API queries
    var studioIds: [String] {
        selectedStudios.map { $0.id }
    }

    /// Get performer IDs for API queries
    var performerIds: [String] {
        selectedPerformers.map { $0.id }
    }

    /// Whether anything is filtering the *photo library* view specifically.
    ///
    /// Not `hasActiveFilters`, which counts the Stash dimensions that a photo
    /// library ignores, and not `photos.hasActiveFilters`, which misses the
    /// shared converted flag. The gallery's "no matches, here is the way out"
    /// state needs exactly this set, and assembling it at the call sites is how
    /// the two would drift.
    var hasActivePhotoLibraryFilters: Bool {
        photosCriteria.hasActiveFilters || showsOnlyConverted
    }

    /// Clears exactly what `hasActivePhotoLibraryFilters` reports, leaving the
    /// Stash criteria alone so switching back does not find them wiped.
    mutating func clearPhotoLibraryFilters() {
        photosCriteria.clearFilters()
        onlyConverted = nil
    }

    /// Whether any filter is active
    var hasActiveFilters: Bool {
        !searchTerm.isEmpty ||
        !selectedGalleries.isEmpty ||
        oCountEnabled ||
        ratingEnabled ||
        !selectedTags.isEmpty ||
        !selectedStudios.isEmpty ||
        !selectedPerformers.isEmpty ||
        showsOnlyConverted
    }

    /// Clear all filters but keep sort settings
    mutating func clearFilters() {
        searchTerm = ""
        selectedGalleries = []
        galleryModifier = .includesAll
        oCountEnabled = false
        oCountModifier = .equals
        oCountValue = nil
        oCountRange = NumberRange()
        ratingEnabled = false
        ratingModifier = .equals
        ratingValue = nil
        ratingRange = NumberRange()
        selectedTags = []
        tagModifier = .includesAll
        selectedStudios = []
        studioModifier = .includesAll
        selectedPerformers = []
        performerModifier = .includesAll
        onlyConverted = nil
        photos?.clearFilters()
    }

    /// Generate a new random seed for random sort
    mutating func shuffleRandomSort() {
        randomSeed = Int.random(in: 10_000_000..<100_000_000)
    }

    /// Convert rating value (1-5 stars) to API value (1-100)
    static func ratingToAPI(_ starRating: Int) -> Int {
        return starRating * 20
    }

    /// Convert API rating (1-100) to star rating (1-5)
    static func ratingFromAPI(_ apiRating: Int) -> Int {
        return max(1, min(5, (apiRating + 10) / 20))
    }
}

// MARK: - Saved View

// MARK: - Scene Filter Criteria

/// Represents a filter for scene/video queries
struct SceneFilterCriteria: Codable, Equatable {
    // Search term (matches title)
    var searchTerm: String = ""

    // Gallery filter - stores full items with names for display
    var selectedGalleries: [AutocompleteItem] = []
    var galleryModifier: CriterionModifier = .includesAll

    // O Count filter
    var oCountEnabled: Bool = false
    var oCountModifier: CriterionModifier = .equals
    var oCountValue: Int?
    var oCountRange: NumberRange = NumberRange()

    // Rating filter (rating100 in Stash, 1-100)
    var ratingEnabled: Bool = false
    var ratingModifier: CriterionModifier = .equals
    var ratingValue: Int?  // 1-5 stars, converted to 1-100 for API
    var ratingRange: NumberRange = NumberRange()  // Also 1-5 stars

    // Tags filter - stores full items with names for display
    var selectedTags: [AutocompleteItem] = []
    var tagModifier: CriterionModifier = .includesAll

    // Studios filter
    var selectedStudios: [AutocompleteItem] = []
    var studioModifier: CriterionModifier = .includesAll

    // Performers filter
    var selectedPerformers: [AutocompleteItem] = []
    var performerModifier: CriterionModifier = .includesAll

    /// Only items this app has already produced 3D output for.
    ///
    /// Lives here rather than in the photo-library criteria because it is the one
    /// dimension that means exactly the same thing in both libraries, and it is
    /// answered the same way in both: `ConvertedMediaRegistry` resolves the
    /// identities, and each source applies them however it can.
    ///
    /// Optional, not a defaulted Bool: the synthesized decoder calls `decode`
    /// for a non-optional even when it has a default, so adding one would have
    /// thrown on every saved view written before this — and the whole array
    /// decodes under one `try?`.
    var onlyConverted: Bool?

    /// `onlyConverted` as a plain Bool, so a Toggle can bind to it.
    var showsOnlyConverted: Bool {
        get { onlyConverted ?? false }
        set { onlyConverted = newValue }
    }

    // Photo-library criteria. Read only when the library in force is Photos —
    // the Stash fields above and these describe two different data models, and
    // the Filters tab shows whichever set belongs to the library being browsed.
    // Optional, not defaulted: see PhotosFilterCriteria for why that matters to
    // saved views written before it existed.
    var photos: PhotosFilterCriteria?

    /// The photo-library half as a non-optional, so SwiftUI can bind straight
    /// into its fields.
    var photosCriteria: PhotosFilterCriteria {
        get { photos ?? PhotosFilterCriteria() }
        set { photos = newValue }
    }

    // Sort options (scene-specific)
    var sortField: SceneSortField = .createdAt
    var sortDirection: SortDirection = .descending
    var randomSeed: Int? = nil  // Random seed for consistent pagination when sorting by random

    /// Get gallery IDs for API queries
    var galleryIds: [String] {
        selectedGalleries.map { $0.id }
    }

    /// Get tag IDs for API queries
    var tagIds: [String] {
        selectedTags.map { $0.id }
    }

    /// Get studio IDs for API queries
    var studioIds: [String] {
        selectedStudios.map { $0.id }
    }

    /// Get performer IDs for API queries
    var performerIds: [String] {
        selectedPerformers.map { $0.id }
    }

    /// Whether anything is filtering the *photo library* view specifically.
    ///
    /// Not `hasActiveFilters`, which counts the Stash dimensions that a photo
    /// library ignores, and not `photos.hasActiveFilters`, which misses the
    /// shared converted flag. The gallery's "no matches, here is the way out"
    /// state needs exactly this set, and assembling it at the call sites is how
    /// the two would drift.
    var hasActivePhotoLibraryFilters: Bool {
        photosCriteria.hasActiveFilters || showsOnlyConverted
    }

    /// Clears exactly what `hasActivePhotoLibraryFilters` reports, leaving the
    /// Stash criteria alone so switching back does not find them wiped.
    mutating func clearPhotoLibraryFilters() {
        photosCriteria.clearFilters()
        onlyConverted = nil
    }

    /// Whether any filter is active
    var hasActiveFilters: Bool {
        !searchTerm.isEmpty ||
        !selectedGalleries.isEmpty ||
        oCountEnabled ||
        ratingEnabled ||
        !selectedTags.isEmpty ||
        !selectedStudios.isEmpty ||
        !selectedPerformers.isEmpty ||
        showsOnlyConverted
    }

    /// Clear all filters but keep sort settings
    mutating func clearFilters() {
        searchTerm = ""
        selectedGalleries = []
        galleryModifier = .includesAll
        oCountEnabled = false
        oCountModifier = .equals
        oCountValue = nil
        oCountRange = NumberRange()
        ratingEnabled = false
        ratingModifier = .equals
        ratingValue = nil
        ratingRange = NumberRange()
        selectedTags = []
        tagModifier = .includesAll
        selectedStudios = []
        studioModifier = .includesAll
        selectedPerformers = []
        performerModifier = .includesAll
        onlyConverted = nil
        photos?.clearFilters()
    }

    /// Generate a new random seed for random sort
    mutating func shuffleRandomSort() {
        randomSeed = Int.random(in: 10_000_000..<100_000_000)
    }

    /// Convert rating value (1-5 stars) to API value (1-100)
    static func ratingToAPI(_ starRating: Int) -> Int {
        return starRating * 20
    }

    /// Convert API rating (1-100) to star rating (1-5)
    static func ratingFromAPI(_ apiRating: Int) -> Int {
        return max(1, min(5, (apiRating + 10) / 20))
    }
}

// MARK: - Saved View

/// A saved filter/sort configuration for images
struct SavedView: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var filter: ImageFilterCriteria
    var createdAt: Date
    var updatedAt: Date
    var isDefault: Bool

    /// Which library this view describes, as a raw string.
    ///
    /// Stored raw and read through `library` so a value written by a future
    /// version decodes to the default instead of throwing — `decodeIfPresent`
    /// on a `RawRepresentable` throws for a present-but-unknown case, and
    /// `loadSavedViews` decodes the whole array under one `try?`, so one bad
    /// element would wipe every saved view.
    ///
    /// Absent means Stash: every view that predates this was written when Stash
    /// was the only library there was.
    var libraryRawValue: String?

    var library: LibrarySource {
        libraryRawValue.flatMap(LibrarySource.init(rawValue:)) ?? .stash
    }

    init(id: UUID = UUID(), name: String, filter: ImageFilterCriteria = ImageFilterCriteria(), isDefault: Bool = false, library: LibrarySource = .stash) {
        self.id = id
        self.name = name
        self.filter = filter
        self.libraryRawValue = library.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isDefault = isDefault
    }

    mutating func updateFilter(_ newFilter: ImageFilterCriteria) {
        self.filter = newFilter
        self.updatedAt = Date()
    }
}

// MARK: - Saved Video View

/// A saved filter/sort configuration for videos
struct SavedVideoView: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var filter: SceneFilterCriteria
    var createdAt: Date
    var updatedAt: Date
    var isDefault: Bool

    /// Which library this view describes, as a raw string.
    ///
    /// Stored raw and read through `library` so a value written by a future
    /// version decodes to the default instead of throwing — `decodeIfPresent`
    /// on a `RawRepresentable` throws for a present-but-unknown case, and
    /// `loadSavedViews` decodes the whole array under one `try?`, so one bad
    /// element would wipe every saved view.
    ///
    /// Absent means Stash: every view that predates this was written when Stash
    /// was the only library there was.
    var libraryRawValue: String?

    var library: LibrarySource {
        libraryRawValue.flatMap(LibrarySource.init(rawValue:)) ?? .stash
    }

    init(id: UUID = UUID(), name: String, filter: SceneFilterCriteria = SceneFilterCriteria(), isDefault: Bool = false, library: LibrarySource = .stash) {
        self.id = id
        self.name = name
        self.filter = filter
        self.libraryRawValue = library.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isDefault = isDefault
    }

    mutating func updateFilter(_ newFilter: SceneFilterCriteria) {
        self.filter = newFilter
        self.updatedAt = Date()
    }
}

// MARK: - Pending Gallery Filter

/// A one-shot request to open a new main gallery window on a specific content
/// tab after the shared filter has been seeded (e.g. tapping a tag in the
/// media info sheet). `id` makes each request distinct so SwiftUI change
/// observers fire even for back-to-back requests.
struct PendingGalleryFilter: Equatable {
    let id = UUID()
    /// True → open the Videos tab (scene filter); false → Pictures tab (image filter).
    let isVideo: Bool
}

// MARK: - Autocomplete Item

/// Generic item for autocomplete lists (tags, galleries)
struct AutocompleteItem: Identifiable, Hashable, Codable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
