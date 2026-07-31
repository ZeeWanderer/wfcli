# AlecaFrame Layout Reference

This development tool renders AlecaFrame relic overlays and desktop planner in headless Chromium and
writes transparent reference images plus measured DOM geometry.

```bash
make aleca-layout-setup
make previews PREVIEW_MEDIA=image PREVIEW_SETS=reference
make previews PREVIEW_MEDIA=video PREVIEW_SETS=reference PREVIEW_SCENES=relic-suggestions
```

Setup queries Overwolf's official installer metadata, downloads the latest
compatible AlecaFrame OPK, extracts it under ignored
`research/alecaframe/<version>/`, and installs Chromium and Node dependencies.
Existing current packages are reused.

For offline setup, pass an OPK or extracted extension:

```bash
./scripts/setup-aleca-layout /path/to/app.opk
```

Outputs use ignored `previews/<resolution>/reference/`. Select resolutions with
`PREVIEW_RESOLUTIONS`; `ALECA_LAYOUT_DPI=1` overrides display scale. Animated
references require FFmpeg with `libvpx-vp9`.
