# Qt GUI

Use Qt model/view for dense or unbounded collections:

- Keep records in `QAbstractItemModel` implementations and render them with a
  `QListView` plus `QStyledItemDelegate`. Do not create one child widget per record.
- Put card geometry in a layout helper shared by painting, tooltips, and hit testing.
- Keep disk, network, image decoding, and expensive transformation out of `paint()`
  and model `data()` calls. Create `QPixmap` objects only on the GUI thread.
- Complete asynchronous work with `update(itemRect)`. Repaint the whole viewport only
  when shared visual state changes. Use `update()`, not synchronous `repaint()`.
- Emit role-specific `dataChanged` ranges. Reset a model only when row identity or
  structure changes, and preserve the visible anchor across reordering.
- Use uniform item sizes and `QListView::SinglePass` where card geometry allows it.
  Change layout mode or widget paint attributes only after measuring the result.

Qt coalesces `update()` calls and clips paint events to dirty regions. Delegates add
application drawing while the view retains virtualization, scrolling, and backing-store
behavior. See the Qt documentation for
[`QAbstractItemView`](https://doc.qt.io/qt-6/qabstractitemview.html),
[`QListView`](https://doc.qt.io/qt-6/qlistview.html), and
[`QWidget` painting](https://doc.qt.io/qt-6/qwidget.html#update).
