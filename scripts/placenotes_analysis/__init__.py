"""PlaceNotes analysis utilities.

Three pure-Python modules, no CLI:
  - pipeline: ST-DBSCAN stay-point + trip extraction
  - trips:    folium/matplotlib renderers for stays and trips
  - places:   global place discovery, filter audit, behavior PCA
"""

from .pipeline import (
    EARTH_RADIUS_M,
    LocationSample,
    StayPoint,
    Trip,
    dbscan_spatial,
    extract_stay_points,
    extract_trips,
    haversine,
    infer_transport_mode,
    load_csv,
    print_summary,
    run_pipeline,
    segment_by_time_gap,
    write_annotated_csv,
    write_trips_json,
)
from .places import (
    Place,
    assign_rejected_to_places,
    cluster_places,
    compute_visits,
    render_behavior_pca,
    render_filter_audit,
    render_places_map,
    render_tod,
    run_place_analysis,
    write_places_csv,
)
from .trips import (
    MODE_COLORS,
    render_day_gantt,
    render_map,
    render_speed_timelines,
    run_trip_visualization,
)

__all__ = [
    "EARTH_RADIUS_M",
    "LocationSample",
    "MODE_COLORS",
    "Place",
    "StayPoint",
    "Trip",
    "assign_rejected_to_places",
    "cluster_places",
    "compute_visits",
    "dbscan_spatial",
    "extract_stay_points",
    "extract_trips",
    "haversine",
    "infer_transport_mode",
    "load_csv",
    "print_summary",
    "render_behavior_pca",
    "render_day_gantt",
    "render_filter_audit",
    "render_map",
    "render_places_map",
    "render_speed_timelines",
    "render_tod",
    "run_pipeline",
    "run_place_analysis",
    "run_trip_visualization",
    "segment_by_time_gap",
    "write_annotated_csv",
    "write_places_csv",
    "write_trips_json",
]
