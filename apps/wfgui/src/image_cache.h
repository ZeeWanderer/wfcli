#pragma once

#include <QPixmap>
#include <QRectF>
#include <QSize>
#include <QString>

class QPainter;

namespace wfgui {

// Decode once at display size. Cache identity includes path, bounds, and DPR.
[[nodiscard]] QPixmap cachedThumbnail(QPainter &painter, const QString &path,
                                      const QSize &logicalBounds);

void drawContained(QPainter &painter, const QRectF &rect, const QPixmap &image);

} // namespace wfgui
