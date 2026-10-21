# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "matplotlib",
# ]
# ///

# Wrapper around debuggraph_zig that runs the zig program, reads bare (binary) output
# from stdout, and converts it to matplotlib graphs.
#
# Usage:
#    uv run debuggraph2.py graph <graph_file>
#    uv run debuggraph2.py plot <json_file>
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


def main():
    parser = argparse.ArgumentParser(
        description="Plot debug data using debuggraph_zig + matplotlib",
    )
    sub = parser.add_subparsers(dest="command")
    p = sub.add_parser("graph", help="Plot a .graph file directly")
    p.add_argument("graph_file", help="Path to the .graph file")

    p = sub.add_parser("plot", help="Plot a JSON config file (or .graph file)")
    p.add_argument("json_file", help="Path to the JSON config or .graph file")

    p = sub.add_parser("resultsof", help="List the output file(s) a JSON config declares")
    p.add_argument(
        "json_file", nargs="?", default="./gthing2.json", help="Path to the JSON config file"
    )

    p = sub.add_parser("list_keys", help="List the column/key names in a debug output file")
    p.add_argument(
        "debug_file", nargs="?", default="./debug_out.txt", help="Path to the debug output file"
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
