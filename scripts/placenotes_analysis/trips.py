"""Visualization of stay points and trips from the ST-DBSCAN pipeline.

Produces three artifacts:
  - <base>_map.html     Folium map with stay points + trip polylines
  - <base>_speed.png    Per-trip speed timelines (accepted vs. rejected)
  - <base>_gantt.png    Day-level timeline of stays and trips
"""

import os

import folium
import matplotlib.dates as mdates
import matplotlib.pyplot as plt

from .pipeline import run_pipeline


MODE_COLORS = {
    "walk": "#2ca02c",
    "bike": "#ff7f0e",
    "drive": "#d62728",
    "unknown": "#7f7f7f",
}


def render_map(samples, stay_points, trips, output_path: str) -> None:
    if not samples:
        print("No samples to render — skipping map")
        return

    center_lat = sum(s.latitude for s in samples) / len(samples)
    center_lon = sum(s.longitude for s in samples) / len(samples)
    m = folium.Map(location=[center_lat, center_lon], zoom_start=14,
                   tiles="CartoDB positron")

    stays_layer = folium.FeatureGroup(name="Stay points")
    for sp in stay_points:
        duration_min = (sp.departure - sp.arrival).total_seconds() / 60
        folium.CircleMarker(
            location=[sp.center_lat, sp.center_lon],
            radius=6 + min(duration_min / 5, 24),
            color="#1f4e79", weight=2,
            fill=True, fill_color="#4f81bd", fill_opacity=0.5,
            popup=folium.Popup(
                f"<b>Stay {sp.cluster_id}</b><br>"
                f"{sp.arrival:%H:%M}–{sp.departure:%H:%M}<br>"
                f"{duration_min:.0f} min · {sp.sample_count} pts · "
                f"r={sp.radius_m:.0f} m",
                max_width=250),
        ).add_to(stays_layer)
    stays_layer.add_to(m)

    trips_layer = folium.FeatureGroup(name="Trips")
    samples_layer = folium.FeatureGroup(name="Trip samples")
    for t in trips:
        color = MODE_COLORS.get(t.transport_mode, "#7f7f7f")
        coords = [(s.latitude, s.longitude) for s in t.samples]
        if len(coords) >= 2:
            avg_kmh = t.avg_speed_ms * 3.6 if t.avg_speed_ms >= 0 else float("nan")
            folium.PolyLine(
                coords, color=color, weight=5, opacity=0.85,
                popup=folium.Popup(
                    f"<b>Trip {t.trip_id}</b><br>"
                    f"mode: {t.transport_mode}<br>"
                    f"{t.start_time:%H:%M}–{t.end_time:%H:%M}<br>"
                    f"{t.distance_m:.0f} m · avg {avg_kmh:.1f} km/h",
                    max_width=260),
            ).add_to(trips_layer)

        for s in t.samples:
            spd = f"{s.speed * 3.6:.1f} km/h" if s.speed >= 0 else "n/a"
            is_accepted = s.filter_status == "accepted"
            folium.CircleMarker(
                location=[s.latitude, s.longitude],
                radius=2.5,
                color="#333" if is_accepted else "#c0392b",
                weight=1,
                fill=True,
                fill_color="#333" if is_accepted else "#c0392b",
                fill_opacity=0.8,
                popup=folium.Popup(
                    f"{s.timestamp:%H:%M:%S}<br>"
                    f"speed: {spd}<br>"
                    f"course: {s.course if s.course is not None else 'n/a'}<br>"
                    f"status: {s.filter_status}",
                    max_width=220),
            ).add_to(samples_layer)
    trips_layer.add_to(m)
    samples_layer.add_to(m)

    folium.LayerControl(collapsed=False).add_to(m)
    m.save(output_path)
    print(f"Map: {output_path}")


def render_speed_timelines(trips, output_path: str) -> None:
    trips_with_samples = [t for t in trips if t.samples]
    n = len(trips_with_samples)
    if n == 0:
        print("No trips with samples — skipping speed timelines")
        return

    fig, axes = plt.subplots(n, 1, figsize=(11, 2.6 * n), squeeze=False)
    axes = axes.flatten()

    for ax, t in zip(axes, trips_with_samples):
        acc = [(s.timestamp, s.speed * 3.6)
               for s in t.samples
               if s.filter_status == "accepted" and s.speed >= 0]
        rej = [(s.timestamp, s.speed * 3.6)
               for s in t.samples
               if s.filter_status != "accepted" and s.speed >= 0]

        if acc:
            ax.scatter([p[0] for p in acc], [p[1] for p in acc],
                       s=22, color="#1f77b4", label=f"accepted ({len(acc)})",
                       zorder=3)
        if rej:
            ax.scatter([p[0] for p in rej], [p[1] for p in rej],
                       s=22, color="#d62728", marker="x",
                       label=f"rejected ({len(rej)})", zorder=3)

        avg_kmh = t.avg_speed_ms * 3.6 if t.avg_speed_ms >= 0 else float("nan")
        max_kmh = t.max_speed_ms * 3.6 if t.max_speed_ms >= 0 else float("nan")
        ax.set_title(
            f"Trip {t.trip_id} · {t.start_time:%H:%M}–{t.end_time:%H:%M} · "
            f"mode={t.transport_mode} · avg {avg_kmh:.1f} km/h · "
            f"max {max_kmh:.1f} km/h",
            fontsize=10,
        )
        ax.set_ylabel("speed (km/h)")
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
        ax.grid(True, alpha=0.3)
        if acc or rej:
            ax.legend(loc="upper right", fontsize=8)

    axes[-1].set_xlabel("time")
    plt.tight_layout()
    plt.savefig(output_path, dpi=130)
    plt.close(fig)
    print(f"Speed timelines: {output_path}")


def render_day_gantt(stay_points, trips, output_path: str) -> None:
    if not stay_points and not trips:
        print("Nothing to plot — skipping gantt")
        return

    fig, ax = plt.subplots(figsize=(14, 2.6))
    legend_seen = set()

    def _bar(start, end, color, label):
        width = mdates.date2num(end) - mdates.date2num(start)
        show_label = label not in legend_seen
        legend_seen.add(label)
        ax.barh(0, width, left=mdates.date2num(start),
                color=color, edgecolor="black", height=0.55,
                label=label if show_label else None)

    for sp in stay_points:
        _bar(sp.arrival, sp.departure, "#4f81bd", "stay")

    for t in trips:
        color = MODE_COLORS.get(t.transport_mode, "#7f7f7f")
        _bar(t.start_time, t.end_time, color, t.transport_mode)

    ax.xaxis_date()
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%m-%d %H:%M"))
    fig.autofmt_xdate()
    ax.set_yticks([])
    ax.set_title("Day timeline · stays and trips")
    ax.legend(loc="upper right", fontsize=9, ncol=4)
    plt.tight_layout()
    plt.savefig(output_path, dpi=130)
    plt.close(fig)
    print(f"Gantt: {output_path}")


def run_trip_visualization(csv_path: str,
                           tau_gap: float = 600,
                           eps: float = 50,
                           min_pts: int = 3,
                           use_all: bool = False,
                           use_rejected_for_trips: bool = False,
                           output_dir: str = "") -> None:
    """Run the pipeline and render all three trip visualizations."""
    samples, _, stay_points, trips = run_pipeline(
        csv_path=csv_path,
        tau_gap=tau_gap,
        eps=eps,
        min_pts=min_pts,
        use_all=use_all,
        use_rejected_for_trips=use_rejected_for_trips,
        output_dir=output_dir,
    )

    out = output_dir or (os.path.dirname(csv_path) or ".")
    base = os.path.splitext(os.path.basename(csv_path))[0]

    render_map(samples, stay_points, trips,
               os.path.join(out, f"{base}_map.html"))
    render_speed_timelines(trips, os.path.join(out, f"{base}_speed.png"))
    render_day_gantt(stay_points, trips, os.path.join(out, f"{base}_gantt.png"))
