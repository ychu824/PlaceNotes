"""Place discovery, filter audit, and behavior PCA on raw location samples.

Two analyses in one pass:
  1. Place discovery — global spatial DBSCAN over accepted samples to surface
     recurring places (home, office, gym, ...).
  2. Filter audit — per-place counts of nearby rejected samples, to see where
     the in-app filter is systematically dropping points.

Plus a behavior-feature PCA over *all* samples (accepted + rejected) to
visualize movement patterns independent of position.
"""

import csv
import os
from dataclasses import dataclass, field

import folium
import matplotlib.pyplot as plt
import numpy as np
from sklearn.cluster import DBSCAN
from sklearn.decomposition import PCA
from sklearn.neighbors import BallTree
from sklearn.preprocessing import StandardScaler

from .pipeline import EARTH_RADIUS_M, haversine, load_csv


@dataclass
class Place:
    place_id: int
    center_lat: float
    center_lon: float
    radius_m: float
    accepted_samples: list
    rejected_samples: list = field(default_factory=list)
    visits: list = field(default_factory=list)  # list[(start, end, n_samples)]

    @property
    def accepted_count(self) -> int:
        return len(self.accepted_samples)

    @property
    def rejected_count(self) -> int:
        return len(self.rejected_samples)

    @property
    def rejected_ratio(self) -> float:
        total = self.accepted_count + self.rejected_count
        return self.rejected_count / total if total else 0.0

    @property
    def total_dwell_seconds(self) -> float:
        return sum((end - start).total_seconds() for start, end, _ in self.visits)

    @property
    def visit_count(self) -> int:
        return len(self.visits)


def cluster_places(accepted, eps_m: float, min_pts: int) -> list[Place]:
    """Global DBSCAN on accepted samples using haversine metric."""
    if not accepted:
        return []

    coords = np.radians([[s.latitude, s.longitude] for s in accepted])
    eps_rad = eps_m / EARTH_RADIUS_M

    db = DBSCAN(eps=eps_rad, min_samples=min_pts, metric="haversine").fit(coords)
    labels = db.labels_

    grouped: dict[int, list] = {}
    for sample, label in zip(accepted, labels):
        if label < 0:
            continue
        grouped.setdefault(int(label), []).append(sample)

    places = []
    for cid, pts in sorted(grouped.items()):
        lat = sum(p.latitude for p in pts) / len(pts)
        lon = sum(p.longitude for p in pts) / len(pts)
        radius = max(haversine(lat, lon, p.latitude, p.longitude) for p in pts)
        places.append(Place(
            place_id=cid,
            center_lat=lat,
            center_lon=lon,
            radius_m=radius,
            accepted_samples=pts,
        ))
    return places


def assign_rejected_to_places(places: list[Place],
                              rejected: list,
                              eps_m: float) -> int:
    """Attach each rejected sample to its nearest place (if within radius+eps).

    Returns the number of rejected samples attached.
    """
    if not places or not rejected:
        return 0

    centers = np.radians([[p.center_lat, p.center_lon] for p in places])
    tree = BallTree(centers, metric="haversine")

    coords = np.radians([[s.latitude, s.longitude] for s in rejected])
    dists, idxs = tree.query(coords, k=1)
    dists_m = dists.flatten() * EARTH_RADIUS_M
    idxs = idxs.flatten()

    attached = 0
    for sample, d_m, i in zip(rejected, dists_m, idxs):
        place = places[i]
        if d_m <= place.radius_m + eps_m:
            place.rejected_samples.append(sample)
            attached += 1
    return attached


def compute_visits(place: Place, visit_gap_s: float) -> None:
    """Split a place's accepted samples into visits separated by time gaps."""
    pts = sorted(place.accepted_samples, key=lambda s: s.timestamp)
    if not pts:
        return

    start = pts[0].timestamp
    prev = pts[0].timestamp
    count = 1
    for s in pts[1:]:
        gap = (s.timestamp - prev).total_seconds()
        if gap > visit_gap_s:
            place.visits.append((start, prev, count))
            start = s.timestamp
            count = 1
        else:
            count += 1
        prev = s.timestamp
    place.visits.append((start, prev, count))


def _ratio_color(ratio: float) -> str:
    """Green (low rejected ratio) → red (high). Clamped at 0.5 for saturation."""
    t = min(ratio * 2.0, 1.0)
    r = int(255 * t)
    g = int(255 * (1.0 - t))
    return f"#{r:02x}{g:02x}00"


def render_places_map(places: list[Place], output_path: str) -> None:
    if not places:
        print("No places to map")
        return

    center_lat = sum(p.center_lat for p in places) / len(places)
    center_lon = sum(p.center_lon for p in places) / len(places)
    m = folium.Map(location=[center_lat, center_lon],
                   zoom_start=13, tiles="CartoDB positron")

    for p in places:
        dwell_min = p.total_dwell_seconds / 60
        folium.CircleMarker(
            location=[p.center_lat, p.center_lon],
            radius=6 + min(dwell_min / 30, 30),
            color="#222", weight=1,
            fill=True,
            fill_color=_ratio_color(p.rejected_ratio),
            fill_opacity=0.75,
            popup=folium.Popup(
                f"<b>Place {p.place_id}</b><br>"
                f"({p.center_lat:.5f}, {p.center_lon:.5f})<br>"
                f"r={p.radius_m:.0f} m · {p.visit_count} visits<br>"
                f"dwell: {dwell_min:.0f} min<br>"
                f"accepted: {p.accepted_count} · "
                f"rejected: {p.rejected_count}<br>"
                f"rejected ratio: {p.rejected_ratio:.1%}",
                max_width=260,
            ),
        ).add_to(m)

    m.save(output_path)
    print(f"Places map: {output_path}")


def render_filter_audit(places: list[Place],
                        total_accepted: int,
                        total_rejected: int,
                        output_path: str) -> None:
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4.2))

    ax1.bar(["accepted", "rejected"],
            [total_accepted, total_rejected],
            color=["#4f81bd", "#c0392b"])
    ax1.set_title("Total sample counts")
    ax1.set_ylabel("count")
    for i, v in enumerate([total_accepted, total_rejected]):
        ax1.text(i, v, f"{v}", ha="center", va="bottom")

    top = sorted(places,
                 key=lambda p: p.accepted_count + p.rejected_count,
                 reverse=True)[:15]
    if top:
        x = np.arange(len(top))
        acc = [p.accepted_count for p in top]
        rej = [p.rejected_count for p in top]
        ax2.bar(x, acc, label="accepted", color="#4f81bd")
        ax2.bar(x, rej, bottom=acc, label="rejected", color="#c0392b")
        ax2.set_xticks(x)
        ax2.set_xticklabels([f"#{p.place_id}" for p in top],
                            rotation=45, ha="right")
        ax2.set_title("Accepted vs. rejected per place (top 15 by volume)")
        ax2.set_ylabel("count")
        ax2.legend()

    plt.tight_layout()
    plt.savefig(output_path, dpi=130)
    plt.close(fig)
    print(f"Filter audit: {output_path}")


def render_tod(places: list[Place], output_path: str, top_n: int = 9) -> None:
    top = sorted(places, key=lambda p: p.total_dwell_seconds,
                 reverse=True)[:top_n]
    if not top:
        print("No places for time-of-day plot")
        return

    cols = 3
    rows = (len(top) + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(12, 3 * rows), squeeze=False)
    flat = axes.flatten()

    for ax, p in zip(flat, top):
        hours = [s.timestamp.hour for s in p.accepted_samples]
        ax.hist(hours, bins=range(25), color="#4f81bd", edgecolor="white")
        ax.set_title(
            f"Place {p.place_id} · "
            f"{p.total_dwell_seconds / 3600:.1f}h dwell · "
            f"{p.visit_count} visits",
            fontsize=10,
        )
        ax.set_xlim(0, 24)
        ax.set_xticks(range(0, 25, 6))
        ax.set_xlabel("hour of day")
        ax.set_ylabel("samples")

    for ax in flat[len(top):]:
        ax.axis("off")

    plt.tight_layout()
    plt.savefig(output_path, dpi=130)
    plt.close(fig)
    print(f"Time-of-day: {output_path}")


def _behavior_features(samples: list) -> tuple[np.ndarray, list[str]]:
    """Build a per-sample behavior feature matrix (no position)."""
    rows = []
    for s in samples:
        speed = max(s.speed, 0.0)
        h_acc = max(s.horizontal_accuracy, 0.0)
        v_acc = max(s.vertical_accuracy, 0.0)
        hour = s.timestamp.hour + s.timestamp.minute / 60.0
        hour_sin = np.sin(2 * np.pi * hour / 24.0)
        hour_cos = np.cos(2 * np.pi * hour / 24.0)
        if s.course is not None and s.course >= 0:
            course_rad = np.radians(s.course)
            course_sin = np.sin(course_rad)
            course_cos = np.cos(course_rad)
        else:
            course_sin = 0.0
            course_cos = 0.0
        rows.append([
            speed,
            np.log1p(h_acc),
            np.log1p(v_acc),
            hour_sin,
            hour_cos,
            course_sin,
            course_cos,
        ])
    names = ["speed", "log_h_acc", "log_v_acc",
             "hour_sin", "hour_cos", "course_sin", "course_cos"]
    return np.array(rows, dtype=float), names


def render_behavior_pca(samples: list, output_path: str) -> None:
    """PCA of per-sample behavior features, colored by motion & filter."""
    if len(samples) < 3:
        print("Too few samples for behavior PCA")
        return

    X, feat_names = _behavior_features(samples)
    X_scaled = StandardScaler().fit_transform(X)
    pca = PCA(n_components=2)
    Z = pca.fit_transform(X_scaled)
    var = pca.explained_variance_ratio_

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5.2))

    activity_colors = {
        "stationary": "#4f81bd",
        "walking": "#2ca02c",
        "running": "#8e44ad",
        "cycling": "#ff7f0e",
        "automotive": "#d62728",
        "unknown": "#7f7f7f",
        "": "#bdc3c7",
    }
    activities = [s.motion_activity or "" for s in samples]
    for act in sorted(set(activities)):
        mask = np.array([a == act for a in activities])
        if not mask.any():
            continue
        ax1.scatter(Z[mask, 0], Z[mask, 1],
                    s=8, alpha=0.55,
                    color=activity_colors.get(act, "#95a5a6"),
                    label=f"{act or 'n/a'} ({int(mask.sum())})")
    ax1.set_title("Behavior PCA — colored by motion activity")
    ax1.set_xlabel(f"PC1 ({var[0]:.1%})")
    ax1.set_ylabel(f"PC2 ({var[1]:.1%})")
    ax1.legend(fontsize=8, loc="best")
    ax1.grid(True, alpha=0.2)

    accepted = np.array([s.filter_status == "accepted" for s in samples])
    ax2.scatter(Z[~accepted, 0], Z[~accepted, 1],
                s=8, alpha=0.5, color="#c0392b",
                label=f"rejected ({int((~accepted).sum())})")
    ax2.scatter(Z[accepted, 0], Z[accepted, 1],
                s=8, alpha=0.5, color="#1f77b4",
                label=f"accepted ({int(accepted.sum())})")
    ax2.set_title("Behavior PCA — colored by filter status")
    ax2.set_xlabel(f"PC1 ({var[0]:.1%})")
    ax2.set_ylabel(f"PC2 ({var[1]:.1%})")
    ax2.legend(fontsize=8, loc="best")
    ax2.grid(True, alpha=0.2)

    loadings = pca.components_
    footer = "PC1: " + ", ".join(
        f"{n}{l:+.2f}" for n, l in zip(feat_names, loadings[0])
    ) + "\nPC2: " + ", ".join(
        f"{n}{l:+.2f}" for n, l in zip(feat_names, loadings[1])
    )
    fig.text(0.5, -0.02, footer, ha="center", va="top", fontsize=8,
             family="monospace")

    plt.tight_layout()
    plt.savefig(output_path, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print(f"Behavior PCA: {output_path}")


def write_places_csv(places: list[Place], output_path: str) -> None:
    with open(output_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "place_id", "center_lat", "center_lon", "radius_m",
            "accepted_count", "rejected_count", "rejected_ratio",
            "visit_count", "total_dwell_minutes",
            "first_seen", "last_seen",
        ])
        for p in places:
            all_ts = [s.timestamp for s in p.accepted_samples]
            writer.writerow([
                p.place_id,
                f"{p.center_lat:.6f}",
                f"{p.center_lon:.6f}",
                f"{p.radius_m:.1f}",
                p.accepted_count,
                p.rejected_count,
                f"{p.rejected_ratio:.3f}",
                p.visit_count,
                f"{p.total_dwell_seconds / 60:.1f}",
                min(all_ts).isoformat() if all_ts else "",
                max(all_ts).isoformat() if all_ts else "",
            ])
    print(f"Places CSV: {output_path}")


def run_place_analysis(csv_path: str,
                       eps: float = 40,
                       min_pts: int = 10,
                       visit_gap: float = 600,
                       output_dir: str = "") -> None:
    """Run place discovery, filter audit, time-of-day, and behavior PCA."""
    all_samples = load_csv(csv_path)
    accepted = [s for s in all_samples if s.filter_status == "accepted"]
    rejected = [s for s in all_samples if s.filter_status != "accepted"]
    print(f"Loaded {len(all_samples)} samples "
          f"({len(accepted)} accepted, {len(rejected)} rejected)")

    places = cluster_places(accepted, eps, min_pts)
    print(f"Discovered {len(places)} places "
          f"(eps={eps}m, min_pts={min_pts})")

    attached = assign_rejected_to_places(places, rejected, eps)
    print(f"Attached {attached}/{len(rejected)} rejected samples to places "
          f"(remaining {len(rejected) - attached} are off-place noise)")

    for p in places:
        compute_visits(p, visit_gap)

    out = output_dir or (os.path.dirname(csv_path) or ".")
    base = os.path.splitext(os.path.basename(csv_path))[0]

    write_places_csv(places, os.path.join(out, f"{base}_places.csv"))
    render_places_map(places, os.path.join(out, f"{base}_places.html"))
    render_filter_audit(places, len(accepted), len(rejected),
                        os.path.join(out, f"{base}_filter_audit.png"))
    render_tod(places, os.path.join(out, f"{base}_tod.png"))
    render_behavior_pca(all_samples,
                        os.path.join(out, f"{base}_behavior.png"))
