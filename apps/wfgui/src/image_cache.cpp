#include "image_cache.h"

#include <QImageIOHandler>
#include <QImageReader>
#include <QPaintDevice>
#include <QPainter>
#include <QPixmapCache>
#include <QtMath>

#include <algorithm>
#include <utility>

namespace wfgui {

QPixmap cachedThumbnail(QPainter &painter, const QString &path,
                        const QSize &logicalBounds) {
  QPixmap image;
  if (path.isEmpty() || logicalBounds.isEmpty()) {
    return image;
  }

  const qreal dpr =
      painter.device() ? painter.device()->devicePixelRatioF() : 1.0;
  const QSize pixelBounds(qCeil(logicalBounds.width() * dpr),
                          qCeil(logicalBounds.height() * dpr));
  const QString key = QString("wfgui-thumb:%1:%2x%3@%4")
                          .arg(path)
                          .arg(pixelBounds.width())
                          .arg(pixelBounds.height())
                          .arg(dpr, 0, 'g', 12);
  if (QPixmapCache::find(key, &image)) {
    return image;
  }

  QImageReader reader(path);
  reader.setAutoTransform(true);
  const QSize sourceSize = reader.size();
  QSize targetSize = sourceSize.isValid()
                         ? sourceSize.scaled(pixelBounds, Qt::KeepAspectRatio)
                         : pixelBounds;
  targetSize.setWidth(std::max(1, targetSize.width()));
  targetSize.setHeight(std::max(1, targetSize.height()));
  if (reader.supportsOption(QImageIOHandler::ScaledSize)) {
    reader.setScaledSize(targetSize);
  }

  QImage decoded = reader.read();
  if (!decoded.isNull() && decoded.size() != targetSize) {
    decoded = decoded.scaled(targetSize, Qt::KeepAspectRatio,
                             Qt::SmoothTransformation);
  }
  if (!decoded.isNull()) {
    image = QPixmap::fromImage(std::move(decoded));
    image.setDevicePixelRatio(dpr);
    QPixmapCache::insert(key, image);
  }
  return image;
}

void drawContained(QPainter &painter, const QRectF &rect,
                   const QPixmap &image) {
  if (image.isNull()) {
    return;
  }
  QSizeF size = image.deviceIndependentSize();
  size.scale(rect.size(), Qt::KeepAspectRatio);
  const QRectF target(QPointF(rect.center().x() - size.width() / 2.0,
                              rect.center().y() - size.height() / 2.0),
                      size);
  painter.drawPixmap(target, image, QRectF(image.rect()));
}

} // namespace wfgui
