# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "matplotlib",
#     "plotly",
# ]
# ///

# Wrapper around debuggraph_zig that runs the zig program, reads bare (binary) output
# from stdout, and converts it to matplotlib graphs or a single interactive HTML page.
#
# Usage:
#    uv run debuggraph2.py graph <graph_file>
#    uv run debuggraph2.py plot <json_file>
#    uv run debuggraph2.py html <graph_file> [more files...] [-o output.html]
#
# The zig program outputs a text header (CHART, SAVE, TITLE, x, y labels) followed
# by raw binary f32 data (little-endian) for each frame, terminated by END.
# This script reads stdout as raw bytes, parses the text header, then reads exact-size
# binary chunks for each frame.

import sys
import os
import subprocess
import struct
import argparse
import html as html_lib
import json
from pathlib import Path

ZIG_CWD = os.path.dirname(os.path.abspath(__file__))


ZIG_EXE = os.path.join(ZIG_CWD, "zig-out", "bin", "debuggraph_zig")


def build_zig():
    subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseFast"],
        cwd=ZIG_CWD,
        check=True,
    )


def run_zig_bare(*args: str) -> bytes:
    build_zig()
    result = subprocess.run(
        [ZIG_EXE, *args, "--out=bare"],
        capture_output=True,
        cwd=ZIG_CWD,
    )
    if result.returncode != 0:
        print(f"debuggraph_zig failed (exit {result.returncode}):", file=sys.stderr)
    # forward any stderr from the graphing executable to our stderr
    sys.stderr.buffer.write(result.stderr)
    sys.stderr.buffer.flush()
    if result.returncode != 0:
        sys.exit(1)
    return result.stdout


def run_zig(json_path: str) -> bytes:
    return run_zig_bare("plot", os.path.abspath(json_path))


def run_zig_graph(graph_path: str) -> bytes:
    return run_zig_bare("graph", os.path.abspath(graph_path))


def run_zig_text(*args: str) -> str:
    build_zig()
    result = subprocess.run(
        [ZIG_EXE, *args],
        capture_output=True,
        cwd=ZIG_CWD,
    )
    if result.returncode != 0:
        print(f"debuggraph_zig failed (exit {result.returncode}):", file=sys.stderr)
    sys.stderr.buffer.write(result.stderr)
    sys.stderr.buffer.flush()
    if result.returncode != 0:
        sys.exit(1)
    return result.stdout.decode("utf-8", errors="replace")


def _parse_text_header(data: bytes, pos: int):
    """Parse text header lines from raw bytes. Returns (metadata_dict, new_pos)."""
    meta = {}
    got_num_y = False
    while pos < len(data):
        eol = data.find(b"\n", pos)
        if eol == -1:
            break
        line = data[pos:eol].decode("utf-8", errors="replace")
        pos = eol + 1

        if line == "CHART":
            continue
        elif line.startswith("SAVE:"):
            meta["save"] = line[5:]
        elif line.startswith("TITLE:"):
            meta["title"] = line[6:]
        elif line.startswith("x:"):
            meta["xlabel"] = line[2:]
        elif line.startswith("ylabel:"):
            meta["ylabel"] = line[7:]
        elif line.startswith("width:"):
            try:
                meta["width"] = int(line[6:])
            except ValueError:
                pass
        elif line.startswith("height:"):
            try:
                meta["height"] = int(line[7:])
            except ValueError:
                pass
        elif line.startswith("dpi:"):
            try:
                meta["dpi"] = int(line[4:])
            except ValueError:
                pass
        elif line.startswith("font."):
            try:
                key = line[5:].split(":", 1)
                meta[f"font_{key[0]}"] = int(key[1])
            except (ValueError, IndexError):
                pass
        elif line.startswith("y:"):
            meta.setdefault("ylabels", []).append(line[2:])
            if got_num_y and len(meta["ylabels"]) >= meta["num_y"]:
                break
        elif not got_num_y:
            try:
                meta["num_y"] = int(line)
                got_num_y = True
            except ValueError:
                pass
        else:
            break

    return meta, pos


def _parse_annotations(data: bytes, pos: int):
    """Parse annotation block from raw bytes. Returns (annotations_list, new_pos).

    Format (after ANNOTATIONS\n<count>\n):
        SKIP\n  or
        x:<value>\n
        y:<value>\n
        text:\nBEGIN\n<text>\nEND\n
        type:<str>\n
        arrow.dx:<int>\n
        arrow.dy:<int>\n
        [optional: style.color:<str>\n style.fontsize:<int>\n style.bbox.boxstyle:<str>\n
         style.bbox.facecolor:<str>\n style.bbox.alpha:<float>\n]

    A SKIP line means the emitter abandoned this annotation; nothing else is
    emitted for it, so the whole annotation is discarded and the next line
    belongs to the next annotation. SKIP can also appear mid-text-block (the
    text was cut short before its END marker).
    """
    if pos >= len(data):
        return [], pos

    # Parse annotation count
    eol = data.find(b"\n", pos)
    if eol == -1:
        return [], pos
    try:
        count = int(data[pos:eol])
    except ValueError:
        return [], pos
    pos = eol + 1

    annotations = []
    for _ in range(count):
        ann = {
            "x": 0.0,
            "y": 0.0,
            "text": "",
            "type": "text",
            "arrow": {"dx": 0, "dy": 0},
            "style": None,
        }
        skipped = False

        def _read_line():
            nonlocal pos
            eol = data.find(b"\n", pos)
            if eol == -1:
                return None
            line = data[pos:eol].decode("utf-8", errors="replace").strip()
            pos = eol + 1
            return line

        # Parse x:<value>
        line = _read_line()
        if line is None:
            break
        if line == "SKIP":
            continue
        if line.startswith("x:"):
            try:
                ann["x"] = float(line[2:])
            except ValueError:
                pass

        # Parse y:<value>
        line = _read_line()
        if line is None:
            break
        if line == "SKIP":
            continue
        if line.startswith("y:"):
            try:
                ann["y"] = float(line[2:])
            except ValueError:
                pass

        # Parse text:\nBEGIN\n...\nEND
        line = _read_line()
        if line is None:
            break
        if line == "SKIP":
            continue
        if line == "text:":
            # Skip BEGIN line
            _read_line()
            # Read line-by-line until END; a SKIP inside the block means the
            # annotation was abandoned mid-text, so discard it entirely.
            text_lines = []
            discarded = False
            while True:
                text_line = _read_line()
                if text_line is None:
                    break
                if text_line == "SKIP":
                    discarded = True
                    break
                if text_line == "END":
                    break
                text_lines.append(text_line)
            if discarded:
                continue
            ann["text"] = "\n".join(text_lines).strip()

        # Parse type:<str>
        line = _read_line()
        if line is None:
            break
        if line == "SKIP":
            continue
        if line.startswith("type:"):
            ann["type"] = line[5:]

        # Parse arrow.dx:<int>
        line = _read_line()
        if line is None:
            break
        if line == "SKIP":
            continue
        if line.startswith("arrow.dx:"):
            try:
                ann["arrow"]["dx"] = int(line[9:])
            except ValueError:
                pass

        # Parse arrow.dy:<int>
        line = _read_line()
        if line is None:
            break
        if line == "SKIP":
            continue
        if line.startswith("arrow.dy:"):
            try:
                ann["arrow"]["dy"] = int(line[9:])
            except ValueError:
                pass

        # Parse optional style lines
        style = {}
        while pos < len(data):
            line_start = pos
            eol = data.find(b"\n", pos)
            if eol == -1:
                break
            line = data[pos:eol].decode("utf-8", errors="replace").strip()
            pos = eol + 1

            if line == "SKIP":
                skipped = True
                break
            elif line.startswith("style."):
                rest = line[6:]
                key, _, val = rest.partition(":")
                style[key] = val
            else:
                # This line is not a style line; back up
                pos = line_start
                break

        if skipped:
            continue

        if style:
            ann["style"] = style

        annotations.append(ann)

    return annotations, pos


def parse_bare_output(data: bytes):
    """Parse the bare (binary) output from debuggraph_zig.

    Format per chart:
        Text header:  CHART\nSAVE:...\nTITLE:...\nx:...\n<num_y>\ny:...\n...
        Binary data:  <(num_y+1) * 4 bytes of little-endian f32>\n  (per frame)
        ANNOTATIONS\n<count>\n<annotations>
        END\n
    """
    charts = []
    pos = 0

    while pos < len(data):
        chart_start = data.find(b"CHART", pos)
        if chart_start == -1:
            break
        pos = chart_start

        meta, pos = _parse_text_header(data, pos)
        if "num_y" not in meta:
            break

        num_y = meta["num_y"]
        num_floats = num_y + 1
        frame_bytes = num_floats * 4
        fmt = f"<{num_floats}f"

        frames = []
        while pos < len(data):
            if pos + frame_bytes > len(data):
                break
            # Check for ANNOTATIONS or END
            if data[pos : pos + 11] == b"ANNOTATIONS":
                break
            if data[pos : pos + 3] == b"END":
                pos = data.find(b"\n", pos)
                if pos == -1:
                    pos = len(data)
                else:
                    pos += 1
                break
            raw = data[pos : pos + frame_bytes]
            pos += frame_bytes
            if pos < len(data) and data[pos : pos + 1] == b"\n":
                pos += 1
            frames.append(struct.unpack(fmt, raw))

        # Parse annotations
        annotations = []
        if pos < len(data) and data[pos : pos + 11] == b"ANNOTATIONS":
            pos += 11  # skip "ANNOTATIONS"
            eol = data.find(b"\n", pos)
            if eol != -1:
                pos = eol + 1  # skip newline after ANNOTATIONS
            annotations, pos = _parse_annotations(data, pos)
            if annotations:
                print(f"  Found {len(annotations)} annotation(s)")

        # Skip past END\n
        if pos < len(data):
            end_pos = data.find(b"END\n", pos)
            if end_pos == -1:
                end_pos = data.find(b"END", pos)
            if end_pos != -1:
                pos = end_pos + 3
                eol = data.find(b"\n", pos)
                if eol != -1:
                    pos = eol + 1
                else:
                    pos = len(data)

        charts.append(
            {
                "title": meta.get("title", ""),
                "save": meta.get("save", ""),
                "xlabel": meta.get("xlabel", ""),
                "ylabel": meta.get("ylabel", ""),
                "ylabels": meta.get("ylabels", []),
                "width": meta.get("width", 0),
                "height": meta.get("height", 0),
                "dpi": meta.get("dpi", 0),
                "font_title": meta.get("font_title", 0),
                "font_xlabel": meta.get("font_xlabel", 0),
                "font_ylabel": meta.get("font_ylabel", 0),
                "font_legend": meta.get("font_legend", 0),
                "font_tick": meta.get("font_tick", 0),
                "frames": frames,
                "annotations": annotations,
            }
        )

    return charts


def plot_chart(chart: dict):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    frames = chart["frames"]
    if not frames:
        print(f"  No data for '{chart['title']}', skipping.")
        return

    ncols = len(frames[0])
    xs = [f[0] for f in frames]
    ys = [[f[i] for f in frames] for i in range(1, ncols)]

    figw = chart.get("width", 0) or 12
    figh = chart.get("height", 0) or 6
    dpi = chart.get("dpi", 0) or None
    fig, ax = plt.subplots(figsize=(figw, figh), dpi=dpi)
    for i, y_vals in enumerate(ys):
        label = chart["ylabels"][i] if i < len(chart["ylabels"]) else f"y{i}"
        ax.plot(xs, y_vals, label=label)

    ax.set_xlabel(chart["xlabel"], fontsize=chart.get("font_xlabel") or None)
    if chart.get("ylabel"):
        ax.set_ylabel(chart["ylabel"], fontsize=chart.get("font_ylabel") or None)
    ax.set_title(chart["title"], fontsize=chart.get("font_title") or None)
    ax.legend(prop={"size": chart["font_legend"]} if chart.get("font_legend") else None)
    ax.grid(True)

    if chart.get("font_tick"):
        ax.tick_params(axis="both", which="major", labelsize=chart["font_tick"])

    # Draw annotations
    for ann in chart.get("annotations", []):
        x_pos = ann["x"]
        y_pos = ann["y"]
        text = ann["text"]
        if not text:
            continue

        style = ann.get("style") or {}
        arrow_dx = ann["arrow"]["dx"]
        arrow_dy = ann["arrow"]["dy"]

        kwargs = {}
        if "fontsize" in style:
            try:
                kwargs["fontsize"] = int(style["fontsize"])
            except ValueError:
                pass
        if "color" in style:
            kwargs["color"] = style["color"]

        bbox = None
        if "bbox.boxstyle" in style:
            bbox = {}
            bbox["boxstyle"] = style.get("bbox.boxstyle", "round")
            if "bbox.facecolor" in style:
                bbox["facecolor"] = style["bbox.facecolor"]
            if "bbox.alpha" in style:
                try:
                    bbox["alpha"] = float(style["bbox.alpha"])
                except ValueError:
                    pass
        if bbox:
            kwargs["bbox"] = bbox

        has_arrow = arrow_dx != 0 or arrow_dy != 0
        if has_arrow:
            text_x = x_pos + arrow_dx
            text_y = y_pos + arrow_dy
            ax.annotate(
                text,
                xy=(x_pos, y_pos),
                xytext=(text_x, text_y),
                arrowprops={"arrowstyle": "->", "relpos": (0, 0)},
                **kwargs,
            )
        else:
            ax.annotate(
                text,
                xy=(x_pos, y_pos),
                xytext=(x_pos, y_pos),
                **kwargs,
            )

    save_path = chart["save"]
    if save_path:
        save_dir = os.path.dirname(save_path)
        if save_dir:
            os.makedirs(save_dir, exist_ok=True)
        fig.savefig(save_path)
        print(f"  Saved: {save_path}")

    plt.close(fig)


def _color_with_alpha(color: str, alpha: str | None) -> str:
    """Apply an alpha value to a hex color when possible."""
    if not color:
        return color
    if alpha is None:
        return color
    try:
        alpha_float = float(alpha)
    except (TypeError, ValueError):
        return color
    if len(color) == 7 and color.startswith("#"):
        try:
            red = int(color[1:3], 16)
            green = int(color[3:5], 16)
            blue = int(color[5:7], 16)
        except ValueError:
            return color
        return f"rgba({red}, {green}, {blue}, {alpha_float})"
    return color


def _plotly_annotation(ann: dict) -> dict:
    """Convert one parsed annotation to Plotly annotation arguments."""
    kwargs = {
        "x": ann["x"],
        "y": ann["y"],
        "xref": "x",
        "yref": "y",
        "text": html_lib.escape(ann["text"]).replace("\n", "<br>"),
    }

    style = ann.get("style") or {}
    font = {}
    if "fontsize" in style:
        try:
            font["size"] = float(style["fontsize"])
        except (TypeError, ValueError):
            pass
    if "color" in style:
        font["color"] = style["color"]
    if font:
        kwargs["font"] = font

    if "bbox.boxstyle" in style:
        facecolor = style.get("bbox.facecolor")
        if facecolor:
            kwargs["bgcolor"] = _color_with_alpha(facecolor, style.get("bbox.alpha"))
        kwargs["borderpad"] = 4

    arrow_dx = float(ann["arrow"]["dx"])
    arrow_dy = float(ann["arrow"]["dy"])
    if arrow_dx != 0 or arrow_dy != 0:
        # The .graph arrow offsets are in data units, matching the matplotlib
        # backend. Use absolute axis references so the arrow stays attached to
        # the data point while zooming.
        kwargs.update(
            {
                "showarrow": True,
                "ax": ann["x"] + arrow_dx,
                "ay": ann["y"] + arrow_dy,
                "axref": "x",
                "ayref": "y",
                "arrowhead": 2,
                "arrowwidth": 1.2,
            }
        )
        if "color" in style:
            kwargs["arrowcolor"] = style["color"]
    else:
        kwargs["showarrow"] = False

    return kwargs


def _chart_to_plotly(chart: dict, index: int):
    """Build a Plotly figure for one chart."""
    import plotly.graph_objects as go

    fig = go.Figure()
    frames = chart["frames"]
    if frames:
        xs = [frame[0] for frame in frames]
        ncols = len(frames[0])
        trace_type = go.Scattergl if len(frames) > 5000 else go.Scatter
        for i in range(1, ncols):
            label = (
                chart["ylabels"][i - 1]
                if i - 1 < len(chart["ylabels"])
                else f"y{i - 1}"
            )
            ys = [frame[i] for frame in frames]
            fig.add_trace(
                trace_type(
                    x=xs,
                    y=ys,
                    mode="lines",
                    name=label,
                    line={"width": 2},
                )
            )

    height = int((chart.get("height") or 6) * (chart.get("dpi") or 100))
    layout = {
        "template": "plotly_white",
        "autosize": True,
        "height": max(height, 320),
        "margin": {"l": 70, "r": 24, "t": 24, "b": 56},
        "dragmode": "zoom",
        "hovermode": "x unified",
        "legend": {
            "orientation": "h",
            "yanchor": "bottom",
            "y": 1.02,
            "xanchor": "right",
            "x": 1,
        },
    }

    xaxis = {}
    if chart.get("xlabel"):
        xaxis["title"] = {"text": chart["xlabel"]}
    if chart.get("font_xlabel"):
        xaxis.setdefault("title", {})["font"] = {"size": chart["font_xlabel"]}
    if chart.get("font_tick"):
        xaxis["tickfont"] = {"size": chart["font_tick"]}
    if xaxis:
        layout["xaxis"] = xaxis

    yaxis = {}
    if chart.get("ylabel"):
        yaxis["title"] = {"text": chart["ylabel"]}
    if chart.get("font_ylabel"):
        yaxis.setdefault("title", {})["font"] = {"size": chart["font_ylabel"]}
    if chart.get("font_tick"):
        yaxis["tickfont"] = {"size": chart["font_tick"]}
    if yaxis:
        layout["yaxis"] = yaxis

    if chart.get("font_legend"):
        layout["legend"]["font"] = {"size": chart["font_legend"]}

    fig.update_layout(**layout)

    for ann in chart.get("annotations", []):
        if not ann.get("text"):
            continue
        fig.add_annotation(**_plotly_annotation(ann))

    return fig


def write_html_report(
    charts: list[dict], out_path: str, input_files: list[str]
) -> Path:
    """Write all charts and annotations to one self-contained interactive HTML file."""
    import plotly.io as pio
    from plotly.offline import get_plotlyjs

    sections = []
    for i, chart in enumerate(charts):
        fig = _chart_to_plotly(chart, i)
        div_id = f"chart-{i}"
        fragment = pio.to_html(
            fig,
            full_html=False,
            include_plotlyjs=False,
            div_id=div_id,
            config={
                "responsive": True,
                "scrollZoom": True,
                "displaylogo": False,
                "toImageButtonOptions": {
                    "format": "png",
                    "filename": f"{Path(input_files[0]).stem}-chart-{i + 1}",
                },
            },
        )
        heading = chart.get("title", "").strip() or f"Chart {i + 1}"
        sections.append(
            f'<section class="chart-card" id="{div_id}-section">\n'
            f"<h2>{html_lib.escape(heading)}</h2>\n"
            f"{fragment}\n"
            "</section>"
        )

    if not sections:
        sections.append(
            '<section class="chart-card"><p>No charts were emitted.</p></section>'
        )

    source_names = ", ".join(html_lib.escape(Path(path).name) for path in input_files)
    page_title = f"graphgen: {Path(input_files[0]).stem}"
    css = """
:root {
    --bg: #f3f4f6;
    --card: #ffffff;
    --text: #111827;
    --muted: #6b7280;
    --border: #e5e7eb;
}
* { box-sizing: border-box; }
body {
    margin: 0;
    padding: 24px;
    background: var(--bg);
    color: var(--text);
    font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont,
        "Segoe UI", sans-serif;
}
header, main {
    width: 100%;
    max-width: 1500px;
    margin-left: auto;
    margin-right: auto;
}
header { margin-bottom: 20px; }
h1 { margin: 0 0 6px; font-size: 1.6rem; }
.hint { margin: 0; color: var(--muted); font-size: 0.9rem; }
main { display: flex; flex-direction: column; gap: 20px; }
.chart-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px 18px 18px;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);
}
.chart-card h2 { margin: 0 0 8px; font-size: 1.05rem; }
.plotly-graph-div { width: 100% !important; }
"""

    document = "\n".join(
        [
            "<!DOCTYPE html>",
            '<html lang="en">',
            "<head>",
            '<meta charset="utf-8">',
            '<meta name="viewport" content="width=device-width, initial-scale=1">',
            f"<title>{html_lib.escape(page_title)}</title>",
            "<style>",
            css,
            "</style>",
            "<script>",
            get_plotlyjs(),
            "</script>",
            "</head>",
            "<body>",
            "<header>",
            f"<h1>{html_lib.escape(page_title)}</h1>",
            f'<p class="hint">Source: {source_names}. '
            "Drag to zoom, scroll to zoom, double-click to reset.</p>",
            "</header>",
            "<main>",
            "\n".join(sections),
            "</main>",
            "</body>",
            "</html>",
        ]
    )

    output = Path(out_path)
    if output.parent:
        output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(document, encoding="utf-8")
    return output


def main():
    parser = argparse.ArgumentParser(
        description="Plot debug data using debuggraph_zig + matplotlib or HTML",
    )
    sub = parser.add_subparsers(dest="command")
    p = sub.add_parser("graph", help="Plot a .graph file directly")
    p.add_argument("graph_file", help="Path to the .graph file")

    p = sub.add_parser("plot", help="Plot a JSON config file (or .graph file)")
    p.add_argument("json_file", help="Path to the JSON config or .graph file")

    p = sub.add_parser(
        "html",
        help="Render one or more inputs to a single interactive HTML report",
    )
    p.add_argument(
        "input_files",
        nargs="+",
        help="Path(s) to .graph or JSON config files",
    )
    p.add_argument(
        "-o",
        "--out",
        dest="out_file",
        default=None,
        help="Output HTML path (default: first input with a .html extension)",
    )

    p = sub.add_parser(
        "resultsof", help="List the output file(s) a JSON config declares"
    )
    p.add_argument(
        "json_file",
        nargs="?",
        default="./gthing2.json",
        help="Path to the JSON config file",
    )

    p = sub.add_parser(
        "list_keys", help="List the column/key names in a debug output file"
    )
    p.add_argument(
        "debug_file",
        nargs="?",
        default="./debug_out.txt",
        help="Path to the debug output file",
    )

    args = parser.parse_args()
    if args.command == "resultsof":
        out = run_zig_text("resultsof", os.path.abspath(args.json_file))
        for line in out.splitlines():
            print(line)
        return

    if args.command == "list_keys":
        out = run_zig_text("list_keys", os.path.abspath(args.debug_file))
        for line in out.splitlines():
            print(line)
        return

    if args.command == "html":
        charts = []
        for path in args.input_files:
            if path.endswith(".graph"):
                print(f"Running debuggraph_zig (graph): {path}")
                raw = run_zig_graph(path)
            else:
                print(f"Running debuggraph_zig (plot): {path}")
                raw = run_zig(path)
            charts.extend(parse_bare_output(raw))

        print(f"Found {len(charts)} chart(s)")
        out_path = args.out_file or str(Path(args.input_files[0]).with_suffix(".html"))
        saved = write_html_report(charts, out_path, args.input_files)
        print(f"Saved HTML: {saved}")
        return

    if args.command in ("graph", "plot"):
        # Route by file extension so `plot foo.graph` also does the right thing.
        path = args.graph_file if args.command == "graph" else args.json_file
        if path.endswith(".graph"):
            print("Running debuggraph_zig (graph)...")
            raw = run_zig_graph(path)
        else:
            print("Running debuggraph_zig (plot)...")
            raw = run_zig(path)
    else:
        parser.print_help()
        sys.exit(1)

    print("Parsing output...")
    charts = parse_bare_output(raw)
    print(f"Found {len(charts)} chart(s)")

    for i, chart in enumerate(charts):
        print(f"\n[{i + 1}/{len(charts)}] {chart['title']}")
        plot_chart(chart)

    print("\nDone.")


if __name__ == "__main__":
    main()
