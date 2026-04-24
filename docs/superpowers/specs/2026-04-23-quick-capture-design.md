# Quick-Capture Design

**Issue:** [#46 — Allow user to take a photo to log current location](https://github.com/ychu824/PlaceNotes/issues/46)
**Date:** 2026-04-23
**Status:** Approved

## Problem

The first tab (`TrackingControlView`) exposes only enable/disable/pause tracking. It wastes prime real estate. Users want to log "I was here" with a photo regardless of dwell length — especially for short, meaningful stops (a viewpoint, a cafe pit-stop) that the dwell detector ignores.

## Goal

A single-tap capture on the first tab: shutter → photo → a `Visit` in the logbook at the user's current place, with a photo-carrying `JournalEntry` attached. Works when tracking is off, works when indoors with poor GPS, and merges cleanly with an already-active or recently-ended dwell visit.

## Decisions

### D1. No-signal fallback — Hybrid

Priority order for resolving the coordinate:

1. Live `CLLocationManager.requestLocation()` one-shot, **only if accuracy ≤ 50 m**.
2. `PHAsset.location` (EXIF embedded in the just-captured photo).
3. Manual picker sheet (existing places list + map-pin drop).

Rationale: EXIF is usually tighter indoors than a one-shot Wi-Fi fix. The 50 m accuracy threshold matches the nearest-place radius (D4) — looser fixes could mis-attribute across close neighbors.

### D2. First-page layout — capture is the hero

- Large circular shutter button centered.
- Tracking state collapses to a compact chip at the top: `● Tracking on` / `⏸ Paused · 2h left` / `○ Tracking off`. Tapping opens a sheet with the existing enable/pause/disable controls.
- Capture works regardless of tracking state (disabled, paused, or active).

### D3. Photo storage — PHAsset + auto-created JournalEntry

- Photo saved to the iOS Photos library via `PHPhotoLibrary.performChanges`.
- `PHAsset.localIdentifier` stored on a new `JournalEntry` with empty title/body and the id in `photoAssetIdentifiers`.
- The entry is linked to the resolved `Place`. Existing views (`PhotoGridView`, `PlaceDetailView`) render it unchanged.

### D4. Place resolution — nearest-first, 50 m

- Fetch `Place`s within 50 m of the resolved coordinate; reuse the nearest if any.
- Otherwise run the full geocode + POI search via the extracted `PlaceResolver.findOrCreate(...)`.

### D5. Merge with existing visit — auto-merge with undo, 30-min window

- If the resolved `Place` has a visit that is active (`departureDate == nil`) **or** ended within the last 30 min, attach the new `JournalEntry` to the same `Place` without creating a new `Visit`.
- Show a toast: `"Added to Home · Split"`. Tapping **Split** creates a new `Visit(arrival: now, departure: now + 60 s)` at the same Place — the `JournalEntry` stays put (journal entries are linked to Place, not Visit), so the photo is now represented by both its Place-level journal entry and an explicit visit row in the logbook.

### D6. Visit duration — small fixed window

- For new visits (non-merge path): `arrivalDate = now`, `departureDate = now + 60 s`. `durationMinutes` returns 1.
- Rationale: non-zero duration reads better in reports than `0 min`, and matches the "brief stop" semantics.

### D7. Location when tracking is off — one-shot

- `LocationOneShot.fetchOnce(timeout: 5 s)` spins up a fresh `CLLocationManager` instance for a single `requestLocation()` call. Uses existing "When In Use" authorization; does not touch the shared dwell manager.

## Architecture

### New files

| File | Role |
|---|---|
| `Services/QuickCaptureService.swift` | Orchestrator. One entry point `capture() async throws -> QuickCaptureResult`. Coordinates location fetch, photo save, place resolution, visit/journal creation, merge decision. |
| `Services/LocationOneShot.swift` | `func fetchOnce(timeout: TimeInterval) async throws -> CLLocation`. Thin wrapper over `CLLocationManager.requestLocation()`. Protocol-seamed for tests. |
| `Services/PlaceResolver.swift` | Extracted from `LocationManager.findOrCreatePlace`. Static methods `nearestOrCreate(coord:context:)` and `findOrCreate(coord:context:)`. |
| `ViewModels/QuickCaptureViewModel.swift` | `@MainActor @Observable` VM. Drives camera sheet, tracks capture state (`idle` / `acquiringLocation` / `savingPhoto` / `resolvingPlace` / `manualPickNeeded` / `done` / `error`), emits toast payload. |
| `Views/ManualPlacePickerView.swift` | Fallback sheet: recent-places list + map-pin drop. Returns a `Place`. |

### Changed files

| File | Change |
|---|---|
| `Views/TrackingControlView.swift` | Rewritten: shutter hero + tracking chip + tracking-controls sheet. |
| `Services/LocationManager.swift` | `findOrCreatePlace` → moved to `PlaceResolver`; `LocationManager` calls `PlaceResolver.findOrCreate` at its existing call sites. No behavioral change for dwell detection. |

### Capture flow

```
Tap shutter
 ├─(parallel)─ LocationOneShot.fetchOnce(timeout: 5s)
 └─(parallel)─ Present camera sheet
User captures photo
 → PHPhotoLibrary.performChanges → PHAsset localIdentifier
 → Resolve coord:
      live fix (acc ≤ 50 m)  →  asset.location  →  ManualPlacePickerView
 → PlaceResolver.nearestOrCreate(coord) (50 m match, else full resolve)
 → Merge decision:
      active visit OR visit ended within 30 min at this Place?
        YES → JournalEntry attached to Place; toast "Added · Split"
        NO  → Visit(arrival: now, departure: now+60s) + JournalEntry; toast "Logged · Undo"
 → modelContext.save() on @MainActor
```

## Error handling

| Condition | Handling |
|---|---|
| Camera permission denied | Alert → Settings. Shutter disabled until granted. |
| Photos add-only permission denied | Alert on first capture. Capture aborts. |
| Location permission not granted | Skip one-shot; use EXIF; else manual pick. No prompt here — tracking owns that onboarding. |
| One-shot times out (5 s) | Fall to EXIF → manual pick. |
| One-shot accuracy > 50 m | Fall to EXIF → manual pick. |
| User cancels camera sheet | VM → `idle`. No photo, no visit. |
| User cancels manual picker after photo was saved | Keep photo in Photos; no Visit/JournalEntry. Toast: "Photo saved, no place logged." |
| PHPhotoLibrary save fails | Alert; no visit created. |
| Geocode fails in full-resolve | `PlaceResolver` creates a Place with "Unnamed Place" + raw coord (existing dwell behavior). |
| `modelContext.save()` throws | `os.Logger` + alert; photo remains in Photos so user can retry. |
| Rapid duplicate taps | VM disables shutter while `state != .idle`. |
| App backgrounded mid-capture | One-shot cancels; EXIF fallback on resume. |

## Testing

- **Unit** — `QuickCaptureService` and `PlaceResolver` against an in-memory `ModelContainer` with a mocked `LocationOneShot`: verify merge decision (active / recent / none), 50 m nearest match, fallback chain.
- **Unit** — `QuickCaptureViewModel` state transitions via XCTest.
- **Seam** — `LocationOneShot` exposes a protocol so tests never touch real `CLLocationManager`.
- **Device smoke** — happy path at new place; capture while dwelling at home (merge + split); airplane mode (EXIF path); Photos-permission-denied flow; tracking-disabled capture.

## Out of scope

- Video capture.
- Editing the auto-created `JournalEntry`'s photo inline during the toast window — user can edit it later from `PlaceDetailView` as with any journal entry.
- CloudKit sync of photos (already out of scope project-wide).
- iPad-specific layout — the shutter layout inherits whatever `TrackingControlView` does today.
