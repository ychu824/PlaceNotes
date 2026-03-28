# PlaceNotes

An iOS app that tracks the places you visit and generates frequency reports and behavior summaries.

## Features

- **Tracking Control** — Enable, disable, or pause tracking (1h / 4h / 24h) with auto-resume
- **Frequent Places** — Weekly (7-day) and monthly (30-day) rankings by qualified stays and total minutes
- **Configurable Stay Threshold** — Only visits exceeding a configurable duration count as qualified stays
- **Interactive Map** — Top places displayed on Apple Maps with category-specific icons and tappable annotations
- **Monthly Report** — Consolidated summary with top places, total tracked time, time-of-day behavior chart
- **Milestone Notifications** — Get notified when a place reaches visit milestones (5, 10, 25, 50, 100)
- **Place Categorization** — Auto-detects place types (Restaurant, Gym, Cafe, Park, etc.) via Apple MapKit

## Requirements

- macOS with Xcode 15+
- iOS 17.0+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for project generation)

## Getting Started

### 1. Install XcodeGen

```bash
brew install xcodegen
```

### 2. Generate the Xcode project

```bash
xcodegen generate
```

This reads `project.yml` and produces `PlaceNotes.xcodeproj`.

### 3. Open in Xcode

```bash
open PlaceNotes.xcodeproj
```

## Running Debug vs Release

### Debug Build (default in Xcode)

Select **Product > Scheme > Edit Scheme > Run > Build Configuration > Debug**, then run on a simulator or device.

Debug mode includes:
- **Mock data seeding** — 8 sample places (cafes, gyms, restaurants, etc.) with randomized visits over 30 days are auto-inserted on first launch, so you can test all views without physically moving around
- No real location tracking required
- Full UI is functional with sample data

### Release Build

Select **Product > Scheme > Edit Scheme > Run > Build Configuration > Release**, then run on a **physical device** (location services don't work well on simulator).

Release mode includes:
- **Real location tracking** via `CLVisit` monitoring (battery-efficient)
- **Auto place categorization** using `MKLocalPointsOfInterestRequest` to detect nearby POIs
- Reverse geocoding for place names
- No mock data — all data comes from actual visits

### Quick Toggle

You can also switch between Debug and Release from the scheme selector:

1. Click the scheme name in Xcode's toolbar
2. **Edit Scheme...** > **Run** > **Info** tab
3. Change **Build Configuration** to `Debug` or `Release`

## Project Structure

```
PlaceNotes/
├── project.yml                         # XcodeGen configuration
├── PlaceNotes/
│   ├── PlaceNotesApp.swift             # App entry point, wires dependencies
│   ├── Info.plist                      # Permissions, background modes
│   ├── Assets.xcassets/
│   ├── Models/
│   │   ├── Place.swift                 # SwiftData — place with coordinates & category
│   │   ├── Visit.swift                 # SwiftData — arrival, departure, time-of-day
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
│       └── SettingsView.swift          # Threshold, milestones, about
```

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI |
| Data | SwiftData |
| Location | Core Location (`CLVisit`) |
| Maps | MapKit |
| Charts | Swift Charts |
| Notifications | UserNotifications |
| Categorization | MapKit POI Search |
| Settings | UserDefaults |

## Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Stable release-ready code |
| `dev` | Active development with debug/release differentiation |

## License

Private project.
