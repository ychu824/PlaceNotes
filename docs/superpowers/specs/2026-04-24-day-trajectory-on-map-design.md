# Day Trajectory on Map — Design

**Date:** 2026-04-24
**Status:** Approved (brainstorm); pending implementation plan

## Purpose

Let the user see the path they walked/drove on a chosen day, rendered on a map and overlaid with the day's Place pins. The feature serves two intents the user identified during brainstorming:

1. **Memory / journaling** — "what did Saturday look like?"
2. **Insight** — "how did I move that day?"

Both are satisfied by a single-day, view-only trajectory map in v1. Date-range views, speed-coloring, and a timeline scrubber are deliberately deferred to later versions but accommodated by the architecture.

## Non-Goals (v1)

- Date-range trajectories (week, trip)
- All-time heatmap / route aggregation
- Tap-to-inspect a polyline point (timestamp/speed popover)
- Animated playback / timeline scrubber
- Speed-coded or plain-color modes (only time-gradient ships)
- Live-tailing while tracking is active
- Cross-midnight stitched trajectories
- Debug visualization of rejected samples

## User Flow

1. User opens the **Logbook** tab and expands a Month section.
2. Each `LogbookVisitRow` exposes a leading `swipeActions` button (`Image(systemName: "map")`, blue tint) labeled "Map".
3. Swiping a visit row right and tapping **Map** pushes `DayTrajectoryView(day:)` onto the existing `NavigationStack`, with `day` set to the local-day of that visit's `arrivalDate`.
4. The screen shows a full-bleed map with that day's path (gradient by time of day) and that day's Place pins.
5. Tapping a Place pin opens the existing `PlaceDetailSheet` (same component already used by the map tab).
6. Back button returns to the Logbook.

**Note on placement:** `LogbookView` currently groups Year → Month → flat list of visits — no day sub-grouping exists. A per-visit entry was chosen over restructuring Logbook into day sections to minimize churn in an unrelated component. Adding day sub-grouping later is independent of this feature.

## Visual Design

- **Polyline color:** time-of-day gradient — morning warm yellow → afternoon orange → evening purple. The gradient is the primary v1 encoding.
- **Place pins:** reuse `PlaceAnnotationView` from `FrequentPlacesMapView` for visual consistency.
- **Header card:** small material-backed card pinned top-center showing:
  - Day formatted (e.g., "Saturday, April 18")
  - Total distance (locale-aware km / mi)
  - "{n} places · {n} samples"
  - Subtitle hint "AM → PM" indicating the gradient direction (no separate legend in v1)
- **Recenter button:** bottom-right floating button matching `FrequentPlacesMapView`.
- **Polyline interactivity:** none in v1 (view-only).

## Architecture

### New files

```
Services/
  TrajectoryBuilder.swift     – pure helpers (enum with static methods)
  TrajectoryStats.swift       – struct of aggregate counts/distance

Views/
  DayTrajectoryView.swift     – the screen
  TrajectoryPolyline.swift    – gradient renderer (View)
  TrajectoryHeaderCard.swift  – floating header
```

### Modified files

- `Views/LogbookView.swift` — add a leading `swipeActions` "Map" button on `LogbookVisitRow`; push `DayTrajectoryView(day:)` for the visit's local-day on tap.

### No changes to

- `LocationManager` (raw samples already persisted at `LocationManager.swift:275`)
- `RawLocationSample` model
- `Place`, `Visit`, `PlaceAnnotationView`, `PlaceDetailSheet`

### Type sketches

```swift
struct TrajectoryPoint {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let normalizedTimeOfDay: Double   // 0..1, computed from local-day boundaries
    let speedMetersPerSecond: Double  // carried for v2 speed-coloring
}

struct TrajectorySegment {
    let points: [TrajectoryPoint]     // contiguous, no gap > maxGapSeconds
}

struct TrajectoryStats {
    let totalDistanceMeters: Double
    let sampleCount: Int
    let segmentCount: Int
    let placeCount: Int
}

enum TrajectoryColorMode {
    case time     // v1 default (only mode shipped)
    case speed    // v2
    case plain    // v2
}

enum TrajectoryBuilder {
    static func build(samples: [RawLocationSample], day: Date) -> [TrajectorySegment]
    static func splitIntoSegments(_ samples: [RawLocationSample], maxGapSeconds: TimeInterval) -> [[RawLocationSample]]
    static func simplify(_ points: [TrajectoryPoint], epsilonMeters: Double) -> [TrajectoryPoint]
    static func computeStats(segments: [TrajectorySegment], placeCount: Int) -> TrajectoryStats
}
```

## Data Flow

`DayTrajectoryView` takes a `Date` (the day) as input.

### Sample query

```swift
let calendar = Calendar.current
let startOfDay = calendar.startOfDay(for: day)
let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

let descriptor = FetchDescriptor<RawLocationSample>(
    predicate: #Predicate {
        $0.timestamp >= startOfDay
        && $0.timestamp < endOfDay
        && $0.filterStatus == "accepted"
    },
    sortBy: [SortDescriptor(\.timestamp)]
)
```

Only `filterStatus == "accepted"` samples are rendered — rejected (low-accuracy / jittery) samples would visually corrupt the path.

### Visit query

A separate `FetchDescriptor<Visit>` with the same date predicate provides pins; each `Visit.place` drives the existing `PlaceAnnotationView`.

### Transformation pipeline

```
[RawLocationSample] (sorted by timestamp)
   → splitIntoSegments(maxGapSeconds: 600)     // break at >10min gaps
   → map each sample → TrajectoryPoint         // compute normalizedTimeOfDay
   → simplify(epsilon: derived from zoom)      // Douglas-Peucker
   → [TrajectorySegment]
```

### Threading

Query + transformation run in a `Task` off the main actor; results hop back to `@MainActor` for `@State` assignment. Mirrors the existing pattern in `LocationManager`.

## Rendering

### Gradient strategy

MapKit's `MapPolyline` only supports a single stroke color, not a per-vertex gradient. v1 draws the path as **N short `MapPolyline` segments**, each colored by its midpoint's `normalizedTimeOfDay`.

With Douglas-Peucker keeping the on-screen vertex count ≤ ~500, this produces a smooth perceived gradient at acceptable cost. A future optimization (drop to UIKit `MKMapView` + custom `MKOverlayRenderer`) is possible but rejected for v1 — adds significant complexity and breaks SwiftUI-`Map` consistency with the rest of the app.

### `TrajectoryPolyline` view

Takes `[TrajectorySegment]` and a `TrajectoryColorMode`. Returns a `MapContentBuilder` of the per-segment polylines. The `ColorMode` enum is the single seam where v2 toggles plug in — adding `.speed` or `.plain` is one additional case in the color function plus a toolbar `Picker`.

## Performance

- **Query:** date + status predicate, sorted; expected to run in milliseconds for a single day.
- **Simplification:** Douglas-Peucker with epsilon ≈ a few meters, capped to ≤ ~500 on-screen vertices. Runs once on appear and once on significant zoom change (debounced).
- **Render:** ~500 short `MapPolyline` segments + ≤ ~10 `PlaceAnnotationView` pins. Within MapKit's comfort zone.
- **Memory:** a day's `RawLocationSample` rows are well under a few MB even at high update rates. SwiftData objects are held only inside the loading `Task`; only transformed `TrajectorySegment` values are retained in `@State`.
- **No new background work, no new permissions, no battery impact** — the feature is read-only on data already collected.

## Privacy

Raw GPS samples never leave the device. Same posture as the rest of the app — SwiftData only, no analytics, no remote calls.

## Edge Cases

| Case | Behavior |
|---|---|
| 0 accepted samples for the day | Map centered on day's visits (or last-known if none); overlay message "No location data recorded for this day". The Logbook button is still shown — it is **not** conditionally hidden per-day. |
| Samples but no visits | Path renders alone. Header reads "0 places · {n} samples". |
| Visits but no samples (e.g., feature added after some history existed) | Pins only. Header card shows "Path data not available for this day". |
| Single-point segment after splitting | Suppressed (not drawable as polyline). Not rendered in v1. |
| Gap > 10 minutes between samples | Polyline breaks at the gap — no "teleport" line drawn across. |
| Today, mid-day | Shows what's been recorded so far. Refreshes only on appear (no live tail in v1). |
| Crossing midnight | Out of scope — local-day filter only. Long stays/drives spanning midnight appear truncated to the selected day. |
| Future date | Cannot occur via Logbook entry (only days with visits are listed). Defensive: clamp input to `Date.now`. |
| DST transition day | `Calendar.startOfDay` handles correctly. |

## Testing

- **Unit tests on `TrajectoryBuilder`** (pure functions, primary coverage):
  - `splitIntoSegments` — boundaries at exactly the gap threshold, multiple gaps, single sample, empty input.
  - `simplify` (Douglas-Peucker) — straight line stays straight, sharp corners preserved, dense colinear points collapse.
  - `computeStats` — distance math against known coordinates, empty input.
- **`DayTrajectoryView`:** no automated test in v1 — view is mostly composition over MapKit and the project does not currently have a snapshot harness. Verify manually on simulator with seeded data.

## Extensibility (Deliberately Reserved)

These are *not* built in v1, but the architecture won't fight us:

- **`ColorMode` toggle** (time / speed / plain) — single enum, single render-time switch, single new toolbar `Picker`.
- **Tap-to-inspect** — `TrajectoryPoint` already carries `timestamp` and `speedMetersPerSecond`; add a tap gesture and a popover.
- **Timeline scrubber** — bottom overlay finding nearest point by `timestamp`; `TrajectoryPoint`s in `@State` are sufficient.
- **Date range** — swap `Date` input for a `DateInterval`, broaden the predicate; rendering layer unchanged.
- **Heatmap / aggregate routes** — can compose on top of `TrajectoryBuilder` since it's pure and SwiftData-free.

No placeholder code, no empty hooks, no unused protocols. Extension points are real types (the enum, the point fields).

## Coding Conventions Adhered To

- `TrajectoryBuilder` is an `enum` with static methods — matches `StayDetector` pattern.
- All SwiftData mutations stay on `@MainActor`; off-main work uses `Task` + hop-back.
- Reuses existing components (`PlaceAnnotationView`, `PlaceDetailSheet`) rather than re-inventing.
- No comments except where the *why* is non-obvious (e.g., gap-splitting rationale, gradient-via-many-segments rationale).
- Pure helpers separated from view code, in `Services/`.

## Implementation Order (high-level — detailed plan to follow)

1. `TrajectoryPoint`, `TrajectorySegment`, `TrajectoryStats`, `TrajectoryColorMode` types.
2. `TrajectoryBuilder` pure helpers + unit tests.
3. `TrajectoryHeaderCard` view.
4. `TrajectoryPolyline` view.
5. `DayTrajectoryView` composition.
6. `LogbookView` button wiring.
7. Manual simulator verification with seeded data covering golden path + edge cases from the table above.
