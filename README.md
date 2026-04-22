# PlaceNotes

An iOS app that tracks the places you visit and generates frequency reports and behavior summaries — with an offline-first trajectory analysis pipeline for trip detection and transportation mode inference.

## Features

* **Tracking Control** — Enable, disable, or pause tracking (1h / 4h / 24h) with auto-resume
* **Frequent Places** — Weekly (7-day) and monthly (30-day) rankings by qualified stays and total minutes
* **Configurable Stay Threshold** — Only visits exceeding a configurable duration count as qualified stays
* **Interactive Map** — Top places displayed on Apple Maps with category-specific icons and tappable annotations
* **Monthly Report** — Consolidated summary with top places, total tracked time, time-of-day behavior chart
* **Milestone Notifications** — Get notified when a place reaches visit milestones (5, 10, 25, 50, 100)
* **Place Categorization** — Auto-detects place types (Restaurant, Gym, Cafe, Park, etc.) via Apple MapKit
* **Raw Location Sampling** — Persists every GPS update with full sensor metadata for offline analysis
* **CSV Export** — Export raw location samples for external trajectory analysis

## Research: Two-Stage ST-DBSCAN for On-Device Trip Detection

PlaceNotes doubles as a research platform for studying lightweight trajectory analysis on mobile devices. The app collects rich GPS data (coordinates, timestamps, speed, course, accuracy) which feeds into an offline analysis pipeline.

### Background

[ST-DBSCAN](https://doi.org/10.1016/j.datak.2006.01.013) (Birant & Kut, 2007) extends classic DBSCAN by adding a temporal distance threshold, enabling density-based clustering on spatiotemporal data. However, vanilla ST-DBSCAN is O(n²), making it impractical for long trajectories on resource-constrained mobile devices.

We propose a **two-stage decomposition** that reduces complexity while preserving detection quality:

```
Raw GPS stream
      │
      ▼
┌─────────────────────────┐
│  Stage 1: Temporal Gap  │   Split trajectory wherever consecutive
│     Segmentation        │   points are > τ_gap apart (default 10 min)
└──────────┬──────────────┘
           │  n segments
           ▼
┌─────────────────────────┐
│  Stage 2: Spatial       │   Run standard DBSCAN (eps, MinPts) within
│     DBSCAN per segment  │   each segment — no time dimension needed
└──────────┬──────────────┘
           │
           ▼
  Stay points + Trips + Transport mode
```

**Complexity**: O(n²) → O(Σ nₖ²), where nₖ is the size of each temporal segment — a significant speedup in practice since most segments contain far fewer points than the full trajectory.

### Analysis Pipeline

The `scripts/` directory contains a zero-dependency Python pipeline:

```bash
# Basic usage — only accepted (filtered) points
python scripts/st_dbscan_pipeline.py data/location_samples.csv

# Include all points (including rejected-speed for transport mode analysis)
python scripts/st_dbscan_pipeline.py data/location_samples.csv --use_all

# Custom parameters
python scripts/st_dbscan_pipeline.py data/location_samples.csv \
    --tau_gap 600 \    # Stage 1: time gap threshold in seconds
    --eps 50 \         # Stage 2: spatial distance in meters
    --min_pts 3        # Stage 2: minimum points per cluster
```

**Output files:**
- `*_annotated.csv` — Original data with added `segment_id`, `cluster_id`, `label` (stay/moving) columns
- `*_trips.json` — Structured trip summaries with origin/destination coordinates, duration, distance, average speed, and inferred transport mode

### Transport Mode Inference

Each detected trip is classified using speed-based heuristics from the `rejected-speed` points (which contain valid GPS readings during motion):

| Mode | Speed range | Source |
|------|------------|--------|
| Walk | < 7.2 km/h | Zheng et al., UbiComp 2008 |
| Bike | 7.2 – 21.6 km/h | Zheng et al., UbiComp 2008 |
| Drive | > 21.6 km/h | Zheng et al., UbiComp 2008 |

### Data Schema

The app persists every `CLLocation` update as a `RawLocationSample` with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `latitude` | Double | WGS84 latitude |
| `longitude` | Double | WGS84 longitude |
| `timestamp` | ISO 8601 | UTC timestamp |
| `horizontalAccuracy` | Double | GPS accuracy in meters |
| `speed` | Double | Speed in m/s (-1 if unavailable) |
| `altitude` | Double | Altitude in meters |
| `verticalAccuracy` | Double | Vertical accuracy in meters |
| `course` | Double | Heading in degrees (0–360) |
| `filterStatus` | String | `accepted` / `rejected-accuracy` / `rejected-speed` |
| `motionActivity` | String | CoreMotion activity (if available) |

### Related Work

This project builds on established trajectory mining research:

- **Birant & Kut (2007)** — *ST-DBSCAN: An algorithm for clustering spatial-temporal data.* Data & Knowledge Engineering. The foundational ST-DBSCAN algorithm.
- **Ester et al. (1996)** — *A Density-Based Algorithm for Discovering Clusters in Large Spatial Databases with Noise.* KDD. The original DBSCAN paper.
- **Zheng et al. (2008)** — *Understanding Mobility Based on GPS Data.* UbiComp. Stay point detection and transport mode classification on the GeoLife dataset (Microsoft Research Asia).
- **Zheng (2015)** — *Trajectory Data Mining: An Overview.* ACM TIST. Comprehensive survey of the field.
- **Chen et al. (2014)** — *T-DBSCAN: A Spatiotemporal Density Clustering for GPS Trajectory Segmentation.* IJGIS. Adds state-continuity and temporal-disjuncture constraints.

### Planned Research Directions

- **LLM-assisted trip annotation** — Using large language models for zero-shot semantic labeling of trips (transport mode, trip purpose) without manual annotation. Inspired by [LLMTrack](https://arxiv.org/abs/2403.06201) (Yang et al., 2024).
- **On-device Swift implementation** — Porting the two-stage pipeline from Python to native Swift for real-time on-device trip detection.
- **GeoLife benchmark** — Evaluating the two-stage approach against vanilla ST-DBSCAN, T-DBSCAN, and HDBSCAN on the [Microsoft GeoLife dataset](https://www.microsoft.com/en-us/download/details.aspx?id=52367).

## Requirements

* macOS with Xcode 15+
* iOS 17.0+ deployment target
* [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for project generation)
* Python 3.9+ (for analysis scripts — no external dependencies required)

## Getting Started

### 1. Install XcodeGen

```
brew install xcodegen
```

### 2. Generate the Xcode project

```
xcodegen generate
```

This reads `project.yml` and produces `PlaceNotes.xcodeproj`.

### 3. Open in Xcode

```
open PlaceNotes.xcodeproj
```

## Running Debug vs Release

### Debug Build (default in Xcode)

Select **Product > Scheme > Edit Scheme > Run > Build Configuration > Debug**, then run on a simulator or device.

Debug mode includes:

* **Mock data seeding** — 8 sample places (cafes, gyms, restaurants, etc.) with randomized visits over 30 days are auto-inserted on first launch, so you can test all views without physically moving around
* No real location tracking required
* Full UI is functional with sample data

### Release Build

Select **Product > Scheme > Edit Scheme > Run > Build Configuration > Release**, then run on a **physical device** (location services don't work well on simulator).

Release mode includes:

* **Real location tracking** via `CLVisit` monitoring (battery-efficient)
* **Auto place categorization** using `MKLocalPointsOfInterestRequest` to detect nearby POIs
* Reverse geocoding for place names
* No mock data — all data comes from actual visits

### Quick Toggle

You can also switch between Debug and Release from the scheme selector:

1. Click the scheme name in Xcode's toolbar
2. **Edit Scheme...** > **Run** > **Info** tab
3. Change **Build Configuration** to `Debug` or `Release`

## Running Tests

### Locally via command line

```
# Generate the project first (if not already done)
xcodegen generate

# Run all 59 unit tests
xcodebuild test \
  -project PlaceNotes.xcodeproj \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

### In Xcode

1. Open `PlaceNotes.xcodeproj`
2. Select the `PlaceNotes` scheme
3. Press **Cmd+U** to run all tests

### CI (GitHub Actions)

Tests run automatically on:

* Every **push to `main`**
* Every **pull request** targeting `main`

The workflow installs XcodeGen, generates the project, builds, and runs all tests. Results are uploaded as an artifact.

### Test coverage

| Test File | Tests | What's covered |
| --- | --- | --- |
| `VisitTests` | 14 | Duration, time-of-day boundaries, active state |
| `PlaceTests` | 7 | Init, coordinate, qualified stays, total minutes |
| `TrackingStateTests` | 15 | Pause/resume logic, Codable, state transitions |
| `ReportGeneratorTests` | 8 | Rankings, date filtering, monthly report |
| `PlaceCategorizerTests` | 8 | Icon/emoji mapping, category consistency |
| `TimeOfDayTests` | 3 | Raw values, Codable round-trip |

## Project Structure

```
PlaceNotes/
├── project.yml                         # XcodeGen configuration
├── scripts/
│   └── st_dbscan_pipeline.py           # Two-stage ST-DBSCAN analysis (Python)
├── PlaceNotes/
│   ├── PlaceNotesApp.swift             # App entry point, wires dependencies
│   ├── Info.plist                      # Permissions, background modes
│   ├── Assets.xcassets/
│   ├── Models/
│   │   ├── Place.swift                 # SwiftData — place with coordinates & category
│   │   ├── Visit.swift                 # SwiftData — arrival, departure, time-of-day
│   │   ├── RawLocationSample.swift     # SwiftData — raw GPS point with sensor metadata
│   │   ├── TrackingState.swift         # Tracking status + pause logic
│   │   └── AppSettings.swift           # Persisted settings (threshold, milestones)
│   ├── Services/
│   │   ├── LocationManager.swift       # CLVisit monitoring + reverse geocoding
│   │   ├── TrackingManager.swift       # Enable/disable/pause/resume with timer
│   │   ├── PlaceCategorizer.swift      # MKLocalSearch POI categorization (release)
│   │   ├── MockLocationProvider.swift  # Sample data seeding (debug only)
│   │   ├── NotificationManager.swift   # Milestone visit notifications
│   │   └── ReportGenerator.swift       # Weekly/monthly rankings + reports
│   ├── ViewModels/
│   │   ├── TrackingViewModel.swift     # Tracking UI state + countdown
│   │   ├── PlacesViewModel.swift       # Frequent places data
│   │   └── ReportViewModel.swift       # Report generation
│   └── Views/
│       ├── ContentView.swift           # Tab bar (5 tabs)
│       ├── TrackingControlView.swift   # Start/stop/pause controls
│       ├── FrequentPlacesView.swift    # Weekly + monthly ranked lists
│       ├── FrequentPlacesMapView.swift # Apple Maps with annotations
│       ├── ReportView.swift            # Monthly report with charts
│       └── SettingsView.swift          # Threshold, milestones, CSV export, about
```

## Tech Stack

| Layer | Technology |
| --- | --- |
| UI | SwiftUI |
| Data | SwiftData |
| Location | Core Location (`CLVisit` + `CLLocation`) |
| Maps | MapKit |
| Charts | Swift Charts |
| Notifications | UserNotifications |
| Categorization | MapKit POI Search |
| Settings | UserDefaults |
| Analysis | Python (standard library only) |

## Branch Strategy

| Branch | Purpose |
| --- | --- |
| `main` | Stable release-ready code |
| `dev` | Active development with debug/release differentiation |

## License

Private project.
