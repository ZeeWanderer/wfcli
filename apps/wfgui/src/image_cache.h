#pragma once

#include <QPixmap>
#include <QRect>
#include <QRectF>
#include <QSize>
#include <QString>

#include <functional>

#include "asset_ref.h"
#include "derivative_cache.h"

class QPainter;

namespace wfgui {

using ImageIssueReporter =
    std::function<void(const AssetRef &, const QString &, bool resolved)>;

// Widget paints schedule disk decode off-thread; cache identity includes bounds
// and DPR.
[[nodiscard]] QPixmap cachedThumbnail(QPainter &painter, const QString &path,
                                      const QSize &logicalBounds,
                                      QRect dirtyRegion = {});
[[nodiscard]] QPixmap cachedThumbnail(QPainter &painter, const AssetRef &asset,
                                      const QSize &logicalBounds,
                                      QRect dirtyRegion = {});

[[nodiscard]] DerivativeCacheStats derivativeCacheStats();
[[nodiscard]] bool clearDerivativeCache();
void clearThumbnailMemoryCache();
[[nodiscard]] qint64 thumbnailMemoryCacheLimit();
void setImageIssueReporter(ImageIssueReporter reporter);

void drawContained(QPainter &painter, const QRectF &rect, const QPixmap &image);

} // namespace wfgui
