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
