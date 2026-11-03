#!/bin/bash
# Renders the link previews (Open Graph, 1200 x 630 JPEG) from scripts/og/og.html into docs/assets:
#   og.jpg         tokenmaccer.app (headline + glass widgets on the desk wallpaper)
#   og-invite.jpg  invitation links /join/<code> (the group widget)
# Run after scripts/render_site_images.sh when the widget pictures change. Needs uv (Playwright, Chromium).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tm-og.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/shot.py" <<'EOF'
import pathlib, sys
from playwright.sync_api import sync_playwright
page, out = pathlib.Path(sys.argv[1]).resolve().as_uri(), sys.argv[2]
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1200, "height": 630}, device_scale_factor=1)
    for v, name in (("home", "og"), ("invite", "og-invite")):
        pg.goto(f"{page}?v={v}")
        pg.wait_for_load_state("networkidle")
        pg.evaluate("() => Promise.all([...document.images].map(i => i.decode().catch(() => 0)))")
        pg.screenshot(path=f"{out}/{name}.png")
    b.close()
EOF
uv run --quiet --with playwright python -I "$WORK/shot.py" scripts/og/og.html "$WORK"
for n in og og-invite; do
    sips -s format jpeg -s formatOptions 88 "$WORK/$n.png" --out "docs/assets/$n.jpg" > /dev/null
    printf '%s %s bytes\n' "docs/assets/$n.jpg" "$(stat -f %z "docs/assets/$n.jpg")"
done
