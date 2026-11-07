# Figures

The figures explain the architecture, the import result, the search path, and
the deployment shape. Each scene is a hand-authored Excalidraw JSON file.
`generate.py` writes the scenes with a fixed palette and a fixed set of
elements, so a change to a box or label produces the same scene on every run.

Render the set:

```bash
chmod +x docs/figures/render.sh
EXCALIDRAW_BROWSER_PATH=/path/to/chrome docs/figures/render.sh
```

The script uses the packaged `excalidraw` CLI with a scale of 2 and a maximum
width of 3200 pixels. It writes one PNG next to each scene. Inspect each PNG
before committing a scene change.

## Rules

- Scene size is 1520 by 940 units with 40 units of margin.
- Every shape uses `roughness: 2`, `fillStyle: "hachure"`, and
  `strokeWidth: 2`.
- Body text is 22 units, the title is 32, and the note is 18.
- Each label stays at six words or fewer.
- The palette maps meaning to color. Blue marks input, purple marks runtime
  code, orange marks analysis, teal marks stored data, red marks risk, and gray
  marks supporting infrastructure.
- Arrows carry a label near the midpoint. Static renders do not depend on
  Excalidraw bindings.

The PNGs are generated artifacts. Commit the scene and the PNG together so the
README and the architecture page render on GitHub without an Excalidraw
install.
