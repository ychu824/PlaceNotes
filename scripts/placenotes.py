# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "folium>=0.15",
#     "matplotlib>=3.7",
#     "numpy>=1.24",
#     "scikit-learn>=1.3",
# ]
# ///
"""PlaceNotes analysis — single entry point.

Interactive:
    uv run scripts/placenotes.py

One-line:
    uv run scripts/placenotes.py pipeline <csv> [--tau_gap 600] [--eps 50] ...
    uv run scripts/placenotes.py trips    <csv> [--use_rejected_for_trips] ...
    uv run scripts/placenotes.py places   <csv> [--eps 40] [--min_pts 10] ...
    uv run scripts/placenotes.py all      <csv> [...]

Subcommands
-----------
  pipeline  ST-DBSCAN stay-point + trip extraction → annotated CSV + trips JSON
  trips     Pipeline + folium map + speed timelines + day Gantt
  places    Global place discovery + filter audit + time-of-day + behavior PCA
  all       Run both `trips` and `places`
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from placenotes_analysis import (  # noqa: E402
    run_pipeline,
    run_place_analysis,
    run_trip_visualization,
)


# ---------------------------------------------------------------------------
# Argparse plumbing
# ---------------------------------------------------------------------------

def _add_pipeline_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("csv", help="Path to PlaceNotes CSV export")
    p.add_argument("--tau_gap", type=float, default=600,
                   help="Time gap threshold in seconds (default: 600)")
    p.add_argument("--eps", type=float, default=50,
                   help="Spatial eps in meters (default: 50)")
    p.add_argument("--min_pts", type=int, default=3,
                   help="Minimum points for a cluster (default: 3)")
    p.add_argument("--use_all", action="store_true",
                   help="Use all points including rejected")
    p.add_argument("--use_rejected_for_trips", action="store_true",
                   help="Detect stay points on accepted only, but include "
                        "rejected inside trip bodies for speed/course stats")
    p.add_argument("--output_dir", default="",
                   help="Output directory (default: same as input)")


def _add_places_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("csv", help="Path to PlaceNotes CSV export")
    p.add_argument("--eps", type=float, default=40,
                   help="DBSCAN eps in meters (default: 40)")
    p.add_argument("--min_pts", type=int, default=10,
                   help="DBSCAN min_samples (default: 10)")
    p.add_argument("--visit_gap", type=float, default=600,
                   help="Gap in seconds that separates visits (default: 600)")
    p.add_argument("--output_dir", default="",
                   help="Output directory (default: same as input)")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="placenotes",
        description="PlaceNotes analysis — pipeline, trip viz, place discovery")
    sub = parser.add_subparsers(dest="cmd")

    p_pipeline = sub.add_parser("pipeline",
                                help="Run the ST-DBSCAN pipeline only")
    _add_pipeline_args(p_pipeline)

    p_trips = sub.add_parser("trips",
                             help="Pipeline + trip visualizations")
    _add_pipeline_args(p_trips)

    p_places = sub.add_parser("places",
                              help="Place discovery + filter audit + behavior PCA")
    _add_places_args(p_places)

    p_all = sub.add_parser("all", help="Run both `trips` and `places`")
    _add_pipeline_args(p_all)
    p_all.add_argument("--place_eps", type=float, default=40,
                       help="Place-discovery eps in meters (default: 40)")
    p_all.add_argument("--place_min_pts", type=int, default=10,
                       help="Place-discovery min_samples (default: 10)")
    p_all.add_argument("--visit_gap", type=float, default=600,
                       help="Gap in seconds that separates visits (default: 600)")

    sub.add_parser("interactive", help="Interactive prompt-driven mode")

    return parser


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def _dispatch_pipeline(args) -> None:
    run_pipeline(
        csv_path=args.csv,
        tau_gap=args.tau_gap,
        eps=args.eps,
        min_pts=args.min_pts,
        use_all=args.use_all,
        use_rejected_for_trips=args.use_rejected_for_trips,
        output_dir=args.output_dir,
    )


def _dispatch_trips(args) -> None:
    run_trip_visualization(
        csv_path=args.csv,
        tau_gap=args.tau_gap,
        eps=args.eps,
        min_pts=args.min_pts,
        use_all=args.use_all,
        use_rejected_for_trips=args.use_rejected_for_trips,
        output_dir=args.output_dir,
    )


def _dispatch_places(args) -> None:
    run_place_analysis(
        csv_path=args.csv,
        eps=args.eps,
        min_pts=args.min_pts,
        visit_gap=args.visit_gap,
        output_dir=args.output_dir,
    )


def _dispatch_all(args) -> None:
    run_trip_visualization(
        csv_path=args.csv,
        tau_gap=args.tau_gap,
        eps=args.eps,
        min_pts=args.min_pts,
        use_all=args.use_all,
        use_rejected_for_trips=args.use_rejected_for_trips,
        output_dir=args.output_dir,
    )
    run_place_analysis(
        csv_path=args.csv,
        eps=args.place_eps,
        min_pts=args.place_min_pts,
        visit_gap=args.visit_gap,
        output_dir=args.output_dir,
    )


# ---------------------------------------------------------------------------
# Interactive mode
# ---------------------------------------------------------------------------

def _prompt(label: str, default, cast=str):
    raw = input(f"{label} [{default}]: ").strip()
    if not raw:
        return default
    try:
        return cast(raw)
    except ValueError:
        print(f"  ! invalid value, using default {default}")
        return default


def _prompt_bool(label: str, default: bool) -> bool:
    suffix = "Y/n" if default else "y/N"
    raw = input(f"{label} [{suffix}]: ").strip().lower()
    if not raw:
        return default
    return raw in ("y", "yes", "true", "1")


def _run_interactive() -> None:
    print("PlaceNotes — interactive mode")
    print("-" * 40)

    csv_path = input("Path to CSV: ").strip().strip('"').strip("'")
    if not csv_path:
        print("No path given — aborting.")
        return
    if not os.path.isfile(csv_path):
        print(f"Not a file: {csv_path}")
        return

    print("\nChoose an action:")
    print("  1) pipeline — stay-point + trip extraction only")
    print("  2) trips    — pipeline + map + speed + gantt")
    print("  3) places   — place discovery + filter audit + behavior PCA")
    print("  4) all      — trips + places")
    choice = input("Choice [2]: ").strip() or "2"

    output_dir = _prompt("Output directory (blank = alongside CSV)", "")

    if choice in ("1", "2"):
        print("\nPipeline parameters:")
        tau_gap = _prompt("  tau_gap (s)", 600.0, float)
        eps = _prompt("  eps (m)", 50.0, float)
        min_pts = _prompt("  min_pts", 3, int)
        use_all = _prompt_bool("  use ALL samples (incl. rejected)?", False)
        use_rej = False
        if not use_all:
            use_rej = _prompt_bool(
                "  fold rejected into trip bodies for speed/course?", True)

        if choice == "1":
            run_pipeline(csv_path, tau_gap, eps, min_pts,
                         use_all, use_rej, output_dir)
        else:
            run_trip_visualization(csv_path, tau_gap, eps, min_pts,
                                   use_all, use_rej, output_dir)

    elif choice == "3":
        print("\nPlace-discovery parameters:")
        eps = _prompt("  eps (m)", 40.0, float)
        min_pts = _prompt("  min_pts", 10, int)
        visit_gap = _prompt("  visit_gap (s)", 600.0, float)
        run_place_analysis(csv_path, eps, min_pts, visit_gap, output_dir)

    elif choice == "4":
        print("\nPipeline parameters (for trips):")
        tau_gap = _prompt("  tau_gap (s)", 600.0, float)
        eps_trip = _prompt("  eps (m)", 50.0, float)
        min_pts_trip = _prompt("  min_pts", 3, int)
        use_all = _prompt_bool("  use ALL samples (incl. rejected)?", False)
        use_rej = False
        if not use_all:
            use_rej = _prompt_bool(
                "  fold rejected into trip bodies?", True)

        print("\nPlace-discovery parameters:")
        eps_place = _prompt("  eps (m)", 40.0, float)
        min_pts_place = _prompt("  min_pts", 10, int)
        visit_gap = _prompt("  visit_gap (s)", 600.0, float)

        run_trip_visualization(csv_path, tau_gap, eps_trip, min_pts_trip,
                               use_all, use_rej, output_dir)
        run_place_analysis(csv_path, eps_place, min_pts_place,
                           visit_gap, output_dir)
    else:
        print(f"Unknown choice: {choice}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    if args.cmd is None or args.cmd == "interactive":
        _run_interactive()
        return

    dispatch = {
        "pipeline": _dispatch_pipeline,
        "trips": _dispatch_trips,
        "places": _dispatch_places,
        "all": _dispatch_all,
    }
    dispatch[args.cmd](args)


if __name__ == "__main__":
    main()
