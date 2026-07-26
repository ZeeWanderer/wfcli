# AlecaFrame Layout Reference

Development-only renderer. It loads AlecaFrame's ignored research copy in a
headless browser, stubs Overwolf APIs, and writes a transparent full-display
reference image plus measured DOM geometry.

```sh
make aleca-layout-setup
make reference-previews
```

Outputs live under ignored `previews/reference/`. Override display assumptions
with `ALECA_LAYOUT_SIZE=1920x1080` and `ALECA_LAYOUT_DPI=1`.
