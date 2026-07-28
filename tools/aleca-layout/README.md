# AlecaFrame Layout Reference

This development tool renders AlecaFrame relic views in headless Chromium and
writes transparent reference images plus measured DOM geometry.

```bash
make aleca-layout-setup
make reference-previews
```

Setup queries Overwolf's official installer metadata, downloads the latest
compatible AlecaFrame OPK, extracts it under ignored
`research/alecaframe/<version>/`, and installs Chromium and Node dependencies.
Existing current packages are reused.

For offline setup, pass an OPK or extracted extension:

```bash
./scripts/setup-aleca-layout /path/to/app.opk
```

Outputs use ignored `previews/reference/`. Set
`ALECA_LAYOUT_SIZE=1920x1080` and `ALECA_LAYOUT_DPI=1` to override display
geometry.
