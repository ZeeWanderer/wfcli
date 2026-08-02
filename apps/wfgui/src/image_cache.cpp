#include "image_cache.h"

#include <QApplication>
#include <QHash>
#include <QImageIOHandler>
#include <QImageReader>
#include <QList>
#include <QPaintDevice>
#include <QPainter>
#include <QPixmapCache>
#include <QPointer>
#include <QSet>
#include <QThread>
#include <QThreadPool>
#include <QWidget>
#include <QtMath>

#include <algorithm>
#include <atomic>
#include <limits>
#include <utility>

namespace {

QImage decodeThumbnail(const QString &path, const QSize &pixelBounds) {
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
  return decoded;
}

QPixmap toPixmap(QImage image, qreal dpr) {
  if (image.isNull()) {
    return {};
  }
  QPixmap pixmap = QPixmap::fromImage(std::move(image));
  pixmap.setDevicePixelRatio(dpr);
  return pixmap;
}

class ThumbnailLoader final : public QObject {
public:
  explicit ThumbnailLoader(QObject *parent) : QObject(parent) {
    pool_.setMaxThreadCount(std::clamp(QThread::idealThreadCount(), 1, 4));
    QPixmapCache::setCacheLimit(
        std::max(QPixmapCache::cacheLimit(), 64 * 1024));
    connect(QApplication::instance(), &QCoreApplication::aboutToQuit, this,
            [this] { stop(); });
  }

  ~ThumbnailLoader() override {
    stop();
    pool_.waitForDone();
  }

  void request(const QString &key, const QString &path,
               const QSize &pixelBounds, qreal dpr, QWidget *target) {
    if (stopping_.load() || failed_.contains(key)) {
      return;
    }

    auto &waiters = waiters_[key];
    const auto targetAlreadyQueued =
        std::any_of(waiters.cbegin(), waiters.cend(),
                    [target](const auto &item) { return item == target; });
    if (!targetAlreadyQueued) {
      waiters.append(target);
    }
    if (pending_.contains(key)) {
      return;
    }
    pending_.insert(key);

    QPointer<ThumbnailLoader> loader(this);
    pool_.start(
        [loader, key, path, pixelBounds, dpr] {
          QImage image = decodeThumbnail(path, pixelBounds);
          if (!loader || loader->stopping_.load()) {
            return;
          }
          QMetaObject::invokeMethod(
              loader,
              [loader, key, image = std::move(image), dpr]() mutable {
                if (loader && !loader->stopping_.load()) {
                  loader->finish(key, std::move(image), dpr);
                }
              },
              Qt::QueuedConnection);
        },
        nextPriority());
  }

private:
  void stop() {
    if (stopping_.exchange(true)) {
      return;
    }
    pool_.clear();
    pending_.clear();
    waiters_.clear();
  }

  int nextPriority() {
    if (priority_ == std::numeric_limits<int>::max()) {
      priority_ = 0;
    }
    return ++priority_;
  }

  void finish(const QString &key, QImage image, qreal dpr) {
    pending_.remove(key);
    if (image.isNull()) {
      failed_.insert(key);
    } else {
      QPixmapCache::insert(key, toPixmap(std::move(image), dpr));
    }
    const auto waiters = waiters_.take(key);
    for (const QPointer<QWidget> &target : waiters) {
      if (target) {
        target->update();
      }
    }
  }

  QThreadPool pool_;
  QSet<QString> pending_;
  QSet<QString> failed_;
  QHash<QString, QList<QPointer<QWidget>>> waiters_;
  std::atomic_bool stopping_ = false;
  int priority_ = 0;
};

ThumbnailLoader *thumbnailLoader() {
  static QPointer<ThumbnailLoader> loader;
  if (!loader) {
    loader = new ThumbnailLoader(QApplication::instance());
  }
  return loader;
}

} // namespace

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

  QWidget *target = dynamic_cast<QWidget *>(painter.device());
  if (target && !path.startsWith(":/")) {
    thumbnailLoader()->request(key, path, pixelBounds, dpr, target);
    return {};
  }

  image = toPixmap(decodeThumbnail(path, pixelBounds), dpr);
  if (!image.isNull()) {
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
