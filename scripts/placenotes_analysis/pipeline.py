"""Two-stage ST-DBSCAN pipeline for stay-point and trip detection.

Stage 1: Temporal gap segmentation (split trajectory by time gaps > tau_gap).
Stage 2: Spatial DBSCAN within each segment to find stay points.
"""

import csv
import json
import math
import os
from dataclasses import dataclass
from datetime import datetime
from typing import Optional


EARTH_RADIUS_M = 6_371_000


@dataclass
class LocationSample:
    """A single GPS sample from RawLocationSample CSV export."""
    id: str
    latitude: float
    longitude: float
    timestamp: datetime
    horizontal_accuracy: float
    speed: float
    altitude: float
    vertical_accuracy: float
    course: Optional[float]
    filter_status: str
    motion_activity: str
    segment_id: int = -1
    cluster_id: int = -1  # -1 = noise (in motion)
    label: str = ""       # "stay" or "moving"


@dataclass
class StayPoint:
    """A detected stay point (cluster of stationary GPS samples)."""
    cluster_id: int
    segment_id: int
    center_lat: float
    center_lon: float
    arrival: datetime
    departure: datetime
    sample_count: int
    radius_m: float


@dataclass
class Trip:
    """A detected trip between two consecutive stay points."""
    trip_id: int
    origin: StayPoint
    destination: StayPoint
    start_time: datetime
    end_time: datetime
    duration_seconds: float
    distance_m: float
    samples: list
    avg_speed_ms: float
    max_speed_ms: float
    transport_mode: str


def haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distance in meters between two (lat, lon) pairs."""
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) *
         math.sin(dlon / 2) ** 2)
    return EARTH_RADIUS_M * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def parse_timestamp(ts_str: str) -> datetime:
    ts_str = ts_str.replace("Z", "+00:00")
    return datetime.fromisoformat(ts_str)


def infer_transport_mode(avg_speed_ms: float, max_speed_ms: float) -> str:
    if avg_speed_ms < 0:
        return "unknown"
    elif avg_speed_ms < 2.0:
        return "walk"
    elif avg_speed_ms < 6.0:
        return "bike"
    elif avg_speed_ms < 50.0:
        return "drive"
    else:
        return "unknown"


def load_csv(path: str) -> list[LocationSample]:
    """Load GPS samples from PlaceNotes CSV export."""
    samples = []
    with open(path, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            course = None
            if row.get("course"):
                try:
                    course = float(row["course"])
                except ValueError:
                    pass

            sample = LocationSample(
                id=row["id"],
                latitude=float(row["latitude"]),
                longitude=float(row["longitude"]),
                timestamp=parse_timestamp(row["timestamp"]),
                horizontal_accuracy=float(row.get("horizontalAccuracy", 0)),
                speed=float(row.get("speed", -1)),
                altitude=float(row.get("altitude", 0)),
                vertical_accuracy=float(row.get("verticalAccuracy", 0)),
                course=course,
                filter_status=row.get("filterStatus", ""),
                motion_activity=row.get("motionActivity", ""),
            )
            samples.append(sample)

    samples.sort(key=lambda s: s.timestamp)
    return samples


def segment_by_time_gap(samples: list[LocationSample],
                        tau_gap_seconds: float = 600) -> list[list[LocationSample]]:
    """Split the trajectory into segments by time gaps > tau_gap_seconds."""
    if not samples:
        return []

    segments = []
    current_segment = [samples[0]]
    samples[0].segment_id = 0

    seg_id = 0
    for i in range(1, len(samples)):
        gap = (samples[i].timestamp - samples[i - 1].timestamp).total_seconds()
        if gap > tau_gap_seconds:
            segments.append(current_segment)
            seg_id += 1
            current_segment = []
        samples[i].segment_id = seg_id
        current_segment.append(samples[i])

    if current_segment:
        segments.append(current_segment)

    return segments


def dbscan_spatial(samples: list[LocationSample],
                   eps_meters: float = 50,
                   min_pts: int = 3,
                   cluster_id_offset: int = 0) -> int:
    """Run DBSCAN on spatial coordinates within a single segment.

    Assigns cluster_id to each sample in-place. Returns the next available
    cluster_id (for offset tracking across segments). Zero external deps.
    """
    n = len(samples)
    if n == 0:
        return cluster_id_offset

    dist = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(i + 1, n):
            d = haversine(samples[i].latitude, samples[i].longitude,
                          samples[j].latitude, samples[j].longitude)
            dist[i][j] = d
            dist[j][i] = d

    def region_query(idx):
        return [j for j in range(n) if dist[idx][j] <= eps_meters]

    labels = [-1] * n
    visited = [False] * n
    cluster = cluster_id_offset

    for i in range(n):
        if visited[i]:
            continue
        visited[i] = True
        neighbors = region_query(i)

        if len(neighbors) < min_pts:
            labels[i] = -1
        else:
            labels[i] = cluster
            seed_set = list(neighbors)
            k = 0
            while k < len(seed_set):
                q = seed_set[k]
                if not visited[q]:
                    visited[q] = True
                    q_neighbors = region_query(q)
                    if len(q_neighbors) >= min_pts:
                        seed_set.extend(q_neighbors)
                if labels[q] == -1:
                    labels[q] = cluster
                k += 1
            cluster += 1

    for i in range(n):
        samples[i].cluster_id = labels[i]
        samples[i].label = "stay" if labels[i] >= 0 else "moving"

    return cluster


def extract_stay_points(samples: list[LocationSample]) -> list[StayPoint]:
    clusters: dict[int, list[LocationSample]] = {}
    for s in samples:
        if s.cluster_id >= 0:
            clusters.setdefault(s.cluster_id, []).append(s)

    stay_points = []
    for cid, points in sorted(clusters.items()):
        center_lat = sum(p.latitude for p in points) / len(points)
        center_lon = sum(p.longitude for p in points) / len(points)
        radius = max(haversine(center_lat, center_lon, p.latitude, p.longitude)
                     for p in points)

        sp = StayPoint(
            cluster_id=cid,
            segment_id=points[0].segment_id,
            center_lat=center_lat,
            center_lon=center_lon,
            arrival=min(p.timestamp for p in points),
            departure=max(p.timestamp for p in points),
            sample_count=len(points),
            radius_m=radius,
        )
        stay_points.append(sp)

    stay_points.sort(key=lambda sp: sp.arrival)
    return stay_points


def extract_trips(samples: list[LocationSample],
                  stay_points: list[StayPoint]) -> list[Trip]:
    """Extract trips between consecutive stay points.

    `samples` may contain rejected points (cluster_id == -1 by default); they
    will be included in trip bodies alongside accepted-but-moving points.
    """
    if len(stay_points) < 2:
        return []

    samples = sorted(samples, key=lambda s: s.timestamp)
    trips = []
    for i in range(len(stay_points) - 1):
        origin = stay_points[i]
        dest = stay_points[i + 1]

        trip_samples = [
            s for s in samples
            if origin.departure <= s.timestamp <= dest.arrival
            and s.cluster_id == -1
        ]

        duration = (dest.arrival - origin.departure).total_seconds()
        distance = haversine(origin.center_lat, origin.center_lon,
                             dest.center_lat, dest.center_lon)

        valid_speeds = [s.speed for s in trip_samples if s.speed >= 0]
        avg_speed = sum(valid_speeds) / len(valid_speeds) if valid_speeds else -1
        max_speed = max(valid_speeds) if valid_speeds else -1

        trip = Trip(
            trip_id=i,
            origin=origin,
            destination=dest,
            start_time=origin.departure,
            end_time=dest.arrival,
            duration_seconds=duration,
            distance_m=distance,
            samples=trip_samples,
            avg_speed_ms=avg_speed,
            max_speed_ms=max_speed,
            transport_mode=infer_transport_mode(avg_speed, max_speed),
        )
        trips.append(trip)

    return trips


def print_summary(samples, segments, stay_points, trips) -> None:
    print("\n" + "=" * 60)
    print("ST-DBSCAN Pipeline Results")
    print("=" * 60)
    print(f"Total samples loaded:    {len(samples)}")
    print(f"Segments (time gaps):    {len(segments)}")
    print(f"Stay points detected:    {len(stay_points)}")
    print(f"Trips detected:          {len(trips)}")

    if stay_points:
        print(f"\n{'─' * 60}")
        print("Stay Points:")
        for sp in stay_points:
            dur = (sp.departure - sp.arrival).total_seconds()
            print(f"  [{sp.cluster_id}] ({sp.center_lat:.5f}, {sp.center_lon:.5f}) "
                  f"  {sp.arrival.strftime('%H:%M')}-{sp.departure.strftime('%H:%M')} "
                  f"  ({dur / 60:.0f} min, {sp.sample_count} pts, r={sp.radius_m:.0f}m)")

    if trips:
        print(f"\n{'─' * 60}")
        print("Trips:")
        for t in trips:
            print(f"  Trip {t.trip_id}: "
                  f"{t.start_time.strftime('%H:%M')}-{t.end_time.strftime('%H:%M')} "
                  f"  {t.duration_seconds / 60:.0f} min, "
                  f"{t.distance_m:.0f}m, "
                  f"avg {t.avg_speed_ms * 3.6:.1f} km/h, "
                  f"mode={t.transport_mode}")


def write_annotated_csv(samples: list[LocationSample], output_path: str) -> None:
    fieldnames = [
        "id", "latitude", "longitude", "timestamp",
        "horizontalAccuracy", "speed", "altitude", "verticalAccuracy",
        "course", "filterStatus", "motionActivity",
        "segment_id", "cluster_id", "label"
    ]
    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for s in samples:
            writer.writerow({
                "id": s.id,
                "latitude": s.latitude,
                "longitude": s.longitude,
                "timestamp": s.timestamp.isoformat(),
                "horizontalAccuracy": s.horizontal_accuracy,
                "speed": s.speed,
                "altitude": s.altitude,
                "verticalAccuracy": s.vertical_accuracy,
                "course": s.course if s.course is not None else "",
                "filterStatus": s.filter_status,
                "motionActivity": s.motion_activity,
                "segment_id": s.segment_id,
                "cluster_id": s.cluster_id,
                "label": s.label,
            })
    print(f"Annotated CSV: {output_path}")


def write_trips_json(trips: list[Trip], output_path: str) -> None:
    data = []
    for t in trips:
        data.append({
            "trip_id": t.trip_id,
            "origin": {"lat": t.origin.center_lat, "lon": t.origin.center_lon},
            "destination": {"lat": t.destination.center_lat, "lon": t.destination.center_lon},
            "start_time": t.start_time.isoformat(),
            "end_time": t.end_time.isoformat(),
            "duration_minutes": round(t.duration_seconds / 60, 1),
            "distance_m": round(t.distance_m),
            "avg_speed_kmh": round(t.avg_speed_ms * 3.6, 1) if t.avg_speed_ms >= 0 else None,
            "max_speed_kmh": round(t.max_speed_ms * 3.6, 1) if t.max_speed_ms >= 0 else None,
            "transport_mode": t.transport_mode,
            "sample_count": len(t.samples),
        })

    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Trips JSON: {output_path}")


def run_pipeline(csv_path: str,
                 tau_gap: float = 600,
                 eps: float = 50,
                 min_pts: int = 3,
                 use_all: bool = False,
                 use_rejected_for_trips: bool = False,
                 output_dir: str = ""):
    """Run the full two-stage ST-DBSCAN pipeline.

    Returns (samples, segments, stay_points, trips).
    """
    all_samples = load_csv(csv_path)
    print(f"Loaded {len(all_samples)} samples from {csv_path}")

    rejected_samples: list[LocationSample] = []
    if use_all:
        samples = all_samples
    else:
        samples = [s for s in all_samples if s.filter_status == "accepted"]
        rejected_samples = [s for s in all_samples if s.filter_status != "accepted"]
        print(f"Using {len(samples)} accepted samples (filtered out "
              f"{len(rejected_samples)} rejected)")

    segments = segment_by_time_gap(samples, tau_gap)
    print(f"Stage 1: {len(segments)} segments (tau_gap={tau_gap}s)")

    cluster_offset = 0
    for seg in segments:
        cluster_offset = dbscan_spatial(seg, eps, min_pts, cluster_offset)
    print(f"Stage 2: {cluster_offset} clusters found (eps={eps}m, min_pts={min_pts})")

    stay_points = extract_stay_points(samples)
    if use_rejected_for_trips and not use_all and rejected_samples:
        trip_pool = samples + rejected_samples
        print(f"Trip inference: folding in {len(rejected_samples)} rejected "
              f"samples for speed/course stats")
    else:
        trip_pool = samples
    trips = extract_trips(trip_pool, stay_points)

    print_summary(samples, segments, stay_points, trips)

    if not output_dir:
        output_dir = os.path.dirname(csv_path) or "."

    base = os.path.splitext(os.path.basename(csv_path))[0]
    write_annotated_csv(samples, os.path.join(output_dir, f"{base}_annotated.csv"))
    write_trips_json(trips, os.path.join(output_dir, f"{base}_trips.json"))

    return samples, segments, stay_points, trips
