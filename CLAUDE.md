# Project Rules

## Git Workflow

- **Always create a new branch from `main` before making any changes.** Never commit directly to `main`.
- Branch naming convention: `feature/`, `fix/`, `chore/` prefixes (e.g., `feature/add-reports`, `fix/tracking-bug`).
- Each branch should be focused on a single change or feature.

---

## App Overview

**PlaceNotes** is an iOS app (Swift / SwiftUI / SwiftData) that passively tracks the user's location and logs meaningful "stays" as named places with timestamped visits. Users can attach journal entries and photos to places, view a logbook of past visits, and generate reports.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI |
| Persistence | SwiftData (iOS 17+) |
| Location | CoreLocation (`CLLocationManager`, `CLVisit`) |
| Maps / POI | MapKit (`MKLocalSearch`, `MKLocalPointsOfInterestRequest`) |
| Geocoding | `CLGeocoder` |
| Language | Swift 5.9+ |
| Build | Xcode / `project.yml` (XcodeGen) |
| CI | GitHub Actions (`.github/workflows/ci.yml`) |

---

## Architecture

```
PlaceNotes/
├── Models/          # SwiftData @Model types
│   ├── Place.swift          – persisted place (centroid lat/lon, name, category)
│   ├── Visit.swift          – arrival/departure timestamps linked to a Place
│   ├── JournalEntry.swift   – user notes attached to a Place
│   ├── CustomCategory.swift – user-defined place categories
│   ├── AppSettings.swift    – singleton settings (min stay minutes, etc.)
│   └── TrackingState.swift  – enum for tracking FSM state
│
├── Services/
│   ├── LocationManager.swift   – CLLocationManager delegate; dwell detection loop
│   ├── StayDetector.swift      – pure-function helpers (weighted center, confidence)
│   ├── PlaceCategorizer.swift  – maps MKPOICategory → emoji / label
│   ├── TrackingManager.swift   – high-level start/stop tracking facade
│   ├── ReportGenerator.swift   – builds summary reports from Visit history
│   └── NotificationManager.swift
│
├── ViewModels/      # ObservableObjects bound to Views
├── Views/           # SwiftUI screens
└── Assets.xcassets/
```

### Key Data Flow

1. `LocationManager.locationManager(_:didUpdateLocations:)` fires every ~10 m.
2. Accurate, stationary samples are appended to `dwellSamples: [LocationSample]`.
3. A 30-second repeating timer (`checkDwellStatus`) checks if `dwellThresholdSeconds` elapsed.
4. When the threshold is met, `StayDetector.buildCluster(from:startDate:)` computes a weighted centroid → `StayCluster`.
5. `recordDwellVisit` reverse-geocodes the centroid, creates / finds a `Place`, inserts a `Visit`.
6. **`dwellSamples` is cleared** — raw GPS points are never persisted.

### `LocationSample` (in-memory only)

```swift
struct LocationSample {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let horizontalAccuracy: CLLocationAccuracy
    let speed: CLLocationSpeed
}
```

---

## ST-DBSCAN Goal (Issue #39)

The goal is to practice **Spatio-Temporal DBSCAN** by persisting the raw `LocationSample` stream and exporting it for offline analysis (Python / pandas / scikit-learn / st_dbscan).

### Why ST-DBSCAN?

The current pipeline uses a simple radius + time threshold to detect stays. ST-DBSCAN can discover variable-density clusters in (lat, lon, time) space without pre-set thresholds, enabling richer stay detection and trajectory segmentation post-hoc.

### Minimum data dimensions for ST-DBSCAN

| Dimension | Source | ST-DBSCAN role |
|-----------|--------|----------------|
| `latitude` | `CLLocation` | Spatial (eps₁) |
| `longitude` | `CLLocation` | Spatial (eps₁) |
| `timestamp` | `CLLocation` | Temporal (eps₂) |
| `horizontalAccuracy` | `CLLocation` | Adaptive weighting / filtering |
| `speed` | `CLLocation` | Trajectory segmentation |
| `altitude` *(stretch)* | `CLLocation` | 3rd spatial dimension |
| `course` *(stretch)* | `CLLocation` | Direction-aware clustering |
| `motionActivity` *(stretch)* | `CMMotionActivity` | Context filtering |

---

## Tasks to Implement (Issue #39)

### 1. `RawLocationSample` SwiftData Model

Add `Models/RawLocationSample.swift`:

```swift
@Model final class RawLocationSample {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var horizontalAccuracy: Double
    var speed: Double
    var altitude: Double?
    var verticalAccuracy: Double?
    var course: Double?
    var filterStatus: String   // "accepted" | "rejected-accuracy" | "rejected-speed"
    var motionActivity: String? // "stationary" | "walking" | "driving" (stretch)
}
```

### 2. Persist samples in `LocationManager`

In `locationManager(_:didUpdateLocations:)`, after building a `LocationSample`, also insert a `RawLocationSample` into `modelContext` with the appropriate `filterStatus` before the existing filter guard.

### 3. CSV / JSON Export

Add an export button (Settings or dedicated screen) using SwiftUI `fileExporter`. Output columns should match the ST-DBSCAN dimension table above.

### 4. Data Retention Policy

Auto-delete `RawLocationSample` records older than a configurable number of days (default 30) to avoid unbounded storage growth.

### Stretch Goals

- Log `CLLocation.altitude`, `verticalAccuracy`, `course`
- Integrate `CMMotionActivityManager` for activity classification
- Cloud backup via CloudKit or S3 presigned URL

---

## Coding Conventions

- No comments unless the **why** is non-obvious.
- Prefer `StayDetector` pure-function helpers for any new detection logic — keeps it unit-testable.
- All SwiftData mutations must happen on `@MainActor` (match existing pattern).
- Keep `LocationManager` focused on collection; heavy processing belongs in `StayDetector` or a new `STDBSCANEngine`.
- Export/analysis utilities should be in `Services/` as standalone types.

---

## Swift Best Practices

### Value Types vs Reference Types

- Use `struct` for data that is copied, compared by value, or passed across concurrency boundaries (e.g., `LocationSample`, `StayCluster`).
- Use `final class` for objects with identity, shared mutable state, or delegate ownership (e.g., `LocationManager`, `TrackingViewModel`).
- Mark classes `final` by default — only drop it when inheritance is explicitly needed.
- Prefer `enum` with static methods for namespaced pure logic with no instance state (e.g., `StayDetector`).

### Optionals

- Use `guard let` for early exit; use `if let` only when both branches are meaningful.
- Avoid force-unwrap (`!`) everywhere except in tests or guaranteed-non-nil outlets. Use `guard` or provide a sensible default instead.
- Prefer `??` for simple fallbacks over a full `if let` block.

```swift
// Prefer
let name = placemark.name ?? placemark.thoroughfare ?? "Unknown Place"

// Avoid
var name: String
if let n = placemark.name { name = n } else { name = "Unknown Place" }
```

### Swift Concurrency

- Annotate ViewModels with `@MainActor` at the class level — eliminates per-method annotation noise and matches the existing pattern.
- Use `Task { @MainActor in }` to hop to the main actor from non-isolated async contexts (e.g., inside `CLLocationManagerDelegate` callbacks).
- Prefer `async/await` over completion handlers for all new async work (geocoding, MapKit, export I/O).
- Use `[weak self]` in Timer callbacks and Combine sinks to avoid retain cycles; in `Task` closures capture `self` weakly only when the enclosing type is a class with a non-trivial lifetime.
- Never call `try?` on a `Task` that could silently swallow meaningful errors — propagate or log them.

```swift
// Correct pattern (matches existing code)
Task { @MainActor in
    let result = await someAsyncOperation()
    self.handleResult(result)
}
```

### Error Handling

- Use `do / try / catch` for recoverable errors surfaced to the user (export failures, geocoding).
- Use `try?` only when a nil result is genuinely acceptable and the error is not actionable (e.g., optional SwiftData fetches).
- Log errors with `os.Logger` before discarding them — never silently drop failures.

### SwiftData

- All `modelContext.insert`, `modelContext.delete`, and `try? modelContext.save()` calls must be on `@MainActor`.
- Fetch with typed `FetchDescriptor<T>` and `#Predicate` — avoid raw string predicates.
- Cascade delete rules belong on the parent model (`@Relationship(deleteRule: .cascade)`), not at call sites.
- Do not hold strong references to `@Model` instances across actor boundaries — refetch by persistent identifier if needed.

```swift
// Correct fetch pattern
let descriptor = FetchDescriptor<RawLocationSample>(
    predicate: #Predicate { $0.timestamp < cutoff },
    sortBy: [SortDescriptor(\.timestamp)]
)
let stale = (try? modelContext.fetch(descriptor)) ?? []
```

### Naming

- Use full words — `horizontalAccuracy`, not `hAcc`. CoreLocation's own API sets the convention.
- Boolean properties read as assertions: `isAccurate`, `isStationary`, `isRecent`.
- Async functions that return a value: verb + noun (`fetchPlace`, `resolveCoordinate`). Async functions with side effects: verb (`recordVisit`, `exportCSV`).
- Avoid type name repetition in property names: `visit.arrivalDate`, not `visit.visitArrivalDate`.

### SwiftUI

- Keep Views as dumb as possible — bind to a ViewModel or pass values directly; no business logic in View bodies.
- Prefer `@StateObject` for ViewModels owned by the view; `@ObservedObject` for injected ones.
- Use `.task { }` modifier for async work tied to a view's lifetime — it cancels automatically on disappear.
- Break large `body` computations into private `@ViewBuilder` computed properties or sub-views, not helper methods returning `some View`.

### Memory & Performance

- Invalidate `Timer` instances in `deinit` or `stopMonitoring` — orphaned timers hold strong references.
- Prefer lazy evaluation (`lazy var`) for expensive computed setup that may never be needed.
- For large SwiftData result sets (e.g., bulk `RawLocationSample` export), stream or batch results rather than loading all rows into memory at once.
- Avoid creating `CLGeocoder` or `MKLocalSearch` instances in tight loops — these are rate-limited by the OS.
