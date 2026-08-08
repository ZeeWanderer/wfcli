#include "image_cache.h"

#include <QApplication>
#include <QDateTime>
#include <QHash>
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

#include "derivative_cache.h"

namespace {
constexpr int MemoryCacheKiB = 64 * 1024;
constexpr qint64 MaximumSourcePixels = 64 * 1024 * 1024;
constexpr int MaximumSourceDimension = 16384;

bool oversized(const QSize &size) {
  return size.isValid() &&
         (size.width() > MaximumSourceDimension ||
          size.height() > MaximumSourceDimension ||
          static_cast<qint64>(size.width()) * size.height() >
              MaximumSourcePixels);
}

QImage normalized(QImage image) {
  if (!image.isNull() && image.hasAlphaChannel() &&
      image.format() != QImage::Format_ARGB32_Premultiplied) {
    return image.convertToFormat(QImage::Format_ARGB32_Premultiplied);
  }
  return image;
}

QImage decodeThumbnail(const QString &path, const QSize &pixelBounds) {
  if (path.isEmpty() || pixelBounds.isEmpty()) {
    return {};
  }
  QImageReader reader(path);
  reader.setAutoTransform(true);
  const QSize source = reader.size();
  if (oversized(source)) {
    return {};
  }

  QImage decoded = reader.read();
  if (decoded.isNull() || oversized(decoded.size())) {
    return {};
  }
  QSize targetSize = decoded.size().scaled(pixelBounds, Qt::KeepAspectRatio);
  targetSize.setWidth(std::max(1, targetSize.width()));
  targetSize.setHeight(std::max(1, targetSize.height()));
  decoded = normalized(std::move(decoded));
  if (decoded.size() != targetSize) {
    decoded = decoded.scaled(targetSize, Qt::IgnoreAspectRatio,
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

wfgui::DerivativeCache &derivativeCache() {
  static wfgui::DerivativeCache cache;
  return cache;
}

class ThumbnailLoader final : public QObject {
public:
  explicit ThumbnailLoader(QObject *parent) : QObject(parent) {
    pool_.setMaxThreadCount(std::clamp(QThread::idealThreadCount(), 1, 4));
    writer_.setMaxThreadCount(1);
    QPixmapCache::setCacheLimit(
        std::max(QPixmapCache::cacheLimit(), MemoryCacheKiB));
    connect(QApplication::instance(), &QCoreApplication::aboutToQuit, this,
            [this] { stop(); });
  }

  ~ThumbnailLoader() override {
    stop();
    pool_.waitForDone();
    writer_.waitForDone();
  }

  void registerAsset(const wfgui::AssetRef &asset) {
    derivativeCache().registerAsset(asset);
  }

  void request(const QString &key, const wfgui::AssetRef &asset,
               const QSize &pixelBounds, qreal dpr, QWidget *target) {
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (stopping_.load()) {
      return;
    }
    const auto failure = failures_.constFind(key);
    if (failure != failures_.cend() && failure->retryAt > now) {
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
        [loader, key, asset, pixelBounds, dpr] {
          if (!loader || loader->stopping_.load()) {
            return;
          }
          QImage image = derivativeCache().load(asset, pixelBounds);
          const bool needsStore = image.isNull() && asset.isPersistent();
          if (image.isNull()) {
            image = decodeThumbnail(asset.path, pixelBounds);
          } else {
            image = normalized(std::move(image));
          }
          if (needsStore && !image.isNull()) {
            loader->storeLater(asset, pixelBounds, image);
          }
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

  void clearMemory() {
    QPixmapCache::clear();
    failures_.clear();
  }

private:
  struct Failure {
    int attempts = 0;
    qint64 retryAt = 0;
  };

  void stop() {
    if (stopping_.exchange(true)) {
      return;
    }
    pool_.clear();
    writer_.clear();
    pending_.clear();
    waiters_.clear();
  }

  int nextPriority() {
    if (priority_ == std::numeric_limits<int>::max()) {
      priority_ = 0;
    }
    return ++priority_;
  }

  void storeLater(const wfgui::AssetRef &asset, const QSize &pixelBounds,
                  const QImage &image) {
    QPointer<ThumbnailLoader> loader(this);
    writer_.start(
        [loader, asset, pixelBounds, image] {
          if (loader && !loader->stopping_.load()) {
            (void)derivativeCache().store(asset, pixelBounds, image);
          }
        },
        -1);
  }

  void finish(const QString &key, QImage image, qreal dpr) {
    pending_.remove(key);
    if (image.isNull()) {
      Failure &failure = failures_[key];
      failure.attempts = std::min(failure.attempts + 1, 6);
      const qint64 delay = std::min<qint64>(60'000, 1000LL << failure.attempts);
      failure.retryAt = QDateTime::currentMSecsSinceEpoch() + delay;
    } else {
      failures_.remove(key);
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
  QThreadPool writer_;
  QSet<QString> pending_;
  QHash<QString, Failure> failures_;
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

QString memoryKey(const wfgui::AssetRef &asset, const QSize &pixelBounds,
                  qreal dpr) {
  const QString identity =
      asset.digest.isEmpty() ? asset.path : asset.digest;
  return QString("wfgui-thumb:contain-v1:%1:%2x%3@%4")
      .arg(identity)
      .arg(pixelBounds.width())
      .arg(pixelBounds.height())
      .arg(dpr, 0, 'g', 12);
}
} // namespace

namespace wfgui {

QPixmap cachedThumbnail(QPainter &painter, const QString &path,
                        const QSize &logicalBounds) {
  return cachedThumbnail(painter, AssetRef::embedded(path, path),
                         logicalBounds);
}

QPixmap cachedThumbnail(QPainter &painter, const AssetRef &asset,
                        const QSize &logicalBounds) {
  QPixmap image;
  if (!asset.isValid() || logicalBounds.isEmpty()) {
    return image;
  }

  const qreal dpr =
      painter.device() ? painter.device()->devicePixelRatioF() : 1.0;
  const QSize pixelBounds(qCeil(logicalBounds.width() * dpr),
                          qCeil(logicalBounds.height() * dpr));
  const QString key = memoryKey(asset, pixelBounds, dpr);
  if (QPixmapCache::find(key, &image)) {
    return image;
  }

  QWidget *target = dynamic_cast<QWidget *>(painter.device());
  if (target && !asset.path.startsWith(":/")) {
    ThumbnailLoader *loader = thumbnailLoader();
    loader->registerAsset(asset);
    loader->request(key, asset, pixelBounds, dpr, target);
    return {};
  }

  image = toPixmap(decodeThumbnail(asset.path, pixelBounds), dpr);
  if (!image.isNull()) {
    QPixmapCache::insert(key, image);
  }
  return image;
}

DerivativeCacheStats derivativeCacheStats() {
  return derivativeCache().stats();
}

bool clearDerivativeCache() {
  return derivativeCache().clear();
}

void clearThumbnailMemoryCache() { thumbnailLoader()->clearMemory(); }

qint64 thumbnailMemoryCacheLimit() {
  return static_cast<qint64>(QPixmapCache::cacheLimit()) * 1024;
}

void drawContained(QPainter &painter, const QRectF &rect,
                   const QPixmap &image) {
  if (image.isNull()) {
    return;
  }
  QSizeF size = image.deviceIndependentSize();
  const qreal dpr = image.devicePixelRatio();
  const qreal tolerance = dpr > 0.0 ? 1.0 / dpr : 1.0;
  if (size.width() > rect.width() + tolerance ||
      size.height() > rect.height() + tolerance) {
    size.scale(rect.size(), Qt::KeepAspectRatio);
    const QRectF target(QPointF(rect.center().x() - size.width() / 2.0,
                                rect.center().y() - size.height() / 2.0),
                        size);
    painter.drawPixmap(target, image, QRectF(image.rect()));
    return;
  }

  QPointF topLeft(rect.center().x() - size.width() / 2.0,
                  rect.center().y() - size.height() / 2.0);
  const qreal paintDpr =
      painter.device() ? painter.device()->devicePixelRatioF() : 1.0;
  if (paintDpr > 0.0) {
    topLeft.setX(qRound(topLeft.x() * paintDpr) / paintDpr);
    topLeft.setY(qRound(topLeft.y() * paintDpr) / paintDpr);
  }
  painter.save();
  painter.setClipRect(rect);
  painter.drawPixmap(topLeft, image);
  painter.restore();
}

} // namespace wfgui
