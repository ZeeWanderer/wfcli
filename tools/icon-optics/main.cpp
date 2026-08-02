#include <QColor>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QHash>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QRegularExpression>
#include <QTextStream>

#include <algorithm>
#include <cmath>
#include <optional>
#include <vector>

namespace {

constexpr int AnalysisPixels = 384;
constexpr qreal AnalysisKeyline = 256.0;
constexpr qreal CellWidth = 164.0;
constexpr qreal CellHeight = 180.0;
constexpr qreal CalibrationCellWidth = 190.0;
constexpr qreal RowLabelWidth = 158.0;
constexpr qreal HeaderHeight = 54.0;
constexpr qreal Margin = 16.0;
constexpr qreal Zoom = 3.0;

struct Backdrop {
  QColor color;
};

struct Icon {
  QString name;
  QString path;
  QImage image;
  QRectF displayBounds;
  QPointF offset;
  qreal contentScale = 1.0;
  qreal calibrationMinimum = 0.0;
  qreal calibrationMaximum = 0.0;
  std::optional<Backdrop> backdrop;
};

struct Profile {
  QString name;
  QHash<QString, qreal> sizes;
};

struct Config {
  QString name;
  QString anchor;
  QColor background;
  QColor canvas;
  qreal slot = 24.0;
  qreal minimumSize = 10.0;
  qreal maximumSize = 24.0;
  qreal silhouetteFraction = 0.2;
  QList<Icon> icons;
  QList<Profile> profiles;
};

struct Metrics {
  qreal alphaMass = 0.0;
  qreal perceptualMass = 0.0;
  qreal envelopeArea = 0.0;
  QPointF alphaCentroid;
  QPointF perceptualCentroid;
};

struct Oklab {
  qreal lightness;
  qreal greenRed;
  qreal blueYellow;
};

QString slug(QString value) {
  value = value.toLower();
  value.replace(QRegularExpression("[^a-z0-9]+"), "-");
  return value.remove(QRegularExpression("(^-+|-+$)"));
}

std::optional<QRectF> parseRect(const QJsonValue &value) {
  const QJsonArray values = value.toArray();
  if (values.size() != 4) {
    return std::nullopt;
  }
  const QRectF result(values.at(0).toDouble(), values.at(1).toDouble(),
                      values.at(2).toDouble(), values.at(3).toDouble());
  return result.isValid() ? std::optional(result) : std::nullopt;
}

std::optional<QPointF> parsePoint(const QJsonValue &value) {
  const QJsonArray values = value.toArray();
  if (values.size() != 2) {
    return std::nullopt;
  }
  return QPointF(values.at(0).toDouble(), values.at(1).toDouble());
}

QString resolvedPath(const QDir &root, const QString &path) {
  return QFileInfo(root.filePath(path)).absoluteFilePath();
}

std::optional<Config> loadConfig(const QString &path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) {
    qCritical("could not open config: %s", qPrintable(path));
    return std::nullopt;
  }
  QJsonParseError error;
  const QJsonDocument document =
      QJsonDocument::fromJson(file.readAll(), &error);
  if (error.error != QJsonParseError::NoError || !document.isObject()) {
    qCritical("could not parse config: %s", qPrintable(error.errorString()));
    return std::nullopt;
  }

  const QJsonObject object = document.object();
  Config config;
  config.name = object.value("name").toString("icons");
  config.anchor = object.value("anchor").toString();
  config.slot = object.value("slot").toDouble(24.0);
  config.minimumSize = object.value("minimum_size").toDouble(config.slot * 0.5);
  config.maximumSize = object.value("maximum_size").toDouble(config.slot);
  config.silhouetteFraction = object.value("silhouette_fraction").toDouble(0.2);
  config.background = QColor(object.value("background").toString("#20283e"));
  config.canvas = QColor(object.value("canvas").toString("#0e1523"));
  if (config.anchor.isEmpty() || config.slot <= 0.0 ||
      config.minimumSize <= 0.0 || config.maximumSize < config.minimumSize ||
      config.silhouetteFraction <= 0.0 || config.silhouetteFraction >= 1.0 ||
      !config.background.isValid() || !config.canvas.isValid()) {
    qCritical("invalid config header");
    return std::nullopt;
  }

  const QDir configDir(QFileInfo(path).absolutePath());
  const QDir assetRoot(
      resolvedPath(configDir, object.value("asset_root").toString(".")));
  const QJsonArray iconValues = object.value("icons").toArray();
  if (iconValues.isEmpty()) {
    qCritical("config has no icons");
    return std::nullopt;
  }

  for (const QJsonValue &value : iconValues) {
    const QJsonObject source = value.toObject();
    Icon icon;
    icon.name = source.value("name").toString();
    icon.path = resolvedPath(assetRoot, source.value("path").toString());
    icon.image = QImage(icon.path);
    if (icon.name.isEmpty() || icon.image.isNull()) {
      qCritical("invalid icon %s at %s", qPrintable(icon.name),
                qPrintable(icon.path));
      return std::nullopt;
    }
    icon.displayBounds = QRectF(icon.image.rect());
    if (source.contains("display_bounds")) {
      const auto bounds = parseRect(source.value("display_bounds"));
      const QRectF imageBounds(0.0, 0.0, icon.image.width(),
                               icon.image.height());
      if (!bounds || !imageBounds.contains(*bounds)) {
        qCritical("invalid display_bounds for %s", qPrintable(icon.name));
        return std::nullopt;
      }
      icon.displayBounds = *bounds;
    }
    if (source.contains("offset")) {
      const auto offset = parsePoint(source.value("offset"));
      if (!offset) {
        qCritical("invalid offset for %s", qPrintable(icon.name));
        return std::nullopt;
      }
      icon.offset = *offset;
    }
    icon.contentScale = source.value("content_scale").toDouble(1.0);
    if (icon.contentScale <= 0.0 || icon.contentScale > 1.0) {
      qCritical("invalid content_scale for %s", qPrintable(icon.name));
      return std::nullopt;
    }
    const QJsonArray calibration = source.value("calibration_range").toArray();
    if (!calibration.isEmpty()) {
      if (calibration.size() != 2) {
        qCritical("invalid calibration_range for %s", qPrintable(icon.name));
        return std::nullopt;
      }
      icon.calibrationMinimum = calibration.at(0).toDouble();
      icon.calibrationMaximum = calibration.at(1).toDouble();
      if (icon.calibrationMinimum <= 0.0 ||
          icon.calibrationMaximum < icon.calibrationMinimum) {
        qCritical("invalid calibration_range for %s", qPrintable(icon.name));
        return std::nullopt;
      }
    }
    if (source.contains("backdrop")) {
      const QJsonObject backdrop = source.value("backdrop").toObject();
      const QColor color(backdrop.value("color").toString());
      if (backdrop.value("shape").toString() != "circle" || !color.isValid()) {
        qCritical("invalid backdrop for %s", qPrintable(icon.name));
        return std::nullopt;
      }
      icon.backdrop = Backdrop{color};
    }
    config.icons.append(std::move(icon));
  }

  if (std::none_of(
          config.icons.cbegin(), config.icons.cend(),
          [&config](const Icon &icon) { return icon.name == config.anchor; })) {
    qCritical("anchor icon not found: %s", qPrintable(config.anchor));
    return std::nullopt;
  }

  for (const QJsonValue &value : object.value("profiles").toArray()) {
    const QJsonObject source = value.toObject();
    Profile profile{.name = source.value("name").toString(), .sizes = {}};
    const QJsonObject sizes = source.value("sizes").toObject();
    if (profile.name.isEmpty()) {
      qCritical("profile has no name");
      return std::nullopt;
    }
    for (const Icon &icon : config.icons) {
      const qreal size = sizes.value(icon.name).toDouble(config.slot);
      if (size <= 0.0 || size > config.slot * 2.0) {
        qCritical("invalid %s size in profile %s", qPrintable(icon.name),
                  qPrintable(profile.name));
        return std::nullopt;
      }
      profile.sizes.insert(icon.name, size);
    }
    config.profiles.append(std::move(profile));
  }
  if (config.profiles.isEmpty()) {
    Profile equal{.name = "Equal frame", .sizes = {}};
    for (const Icon &icon : config.icons) {
      equal.sizes.insert(icon.name, config.slot);
    }
    config.profiles.append(std::move(equal));
  }
  return config;
}

QRectF centered(const QRectF &bounds, qreal size) {
  return {bounds.center().x() - size / 2.0, bounds.center().y() - size / 2.0,
          size, size};
}

void drawIcon(QPainter &painter, const QRectF &target, const Icon &icon,
              qreal slot) {
  painter.save();
  const qreal offsetScale = target.width() / slot;
  const QRectF shifted = target.translated(icon.offset * offsetScale);
  if (icon.backdrop) {
    painter.setPen(Qt::NoPen);
    painter.setBrush(icon.backdrop->color);
    painter.drawEllipse(shifted);
  }

  const QRectF content = centered(shifted, shifted.width() * icon.contentScale);
  const qreal scale = std::min(content.width() / icon.displayBounds.width(),
                               content.height() / icon.displayBounds.height());
  const QSizeF frameSize(icon.displayBounds.width() * scale,
                         icon.displayBounds.height() * scale);
  const QRectF frame(content.center().x() - frameSize.width() / 2.0,
                     content.center().y() - frameSize.height() / 2.0,
                     frameSize.width(), frameSize.height());
  const QRectF image(frame.left() - icon.displayBounds.left() * scale,
                     frame.top() - icon.displayBounds.top() * scale,
                     icon.image.width() * scale, icon.image.height() * scale);
  painter.drawImage(image, icon.image);
  painter.restore();
}

qreal linearChannel(qreal value) {
  value /= 255.0;
  return value <= 0.04045 ? value / 12.92
                          : std::pow((value + 0.055) / 1.055, 2.4);
}

Oklab toOklab(qreal red, qreal green, qreal blue) {
  const qreal l =
      0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue;
  const qreal m =
      0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue;
  const qreal s =
      0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue;
  const qreal lRoot = std::cbrt(l);
  const qreal mRoot = std::cbrt(m);
  const qreal sRoot = std::cbrt(s);
  return {
      0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
      1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
      0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot,
  };
}

qreal colorDistance(const Oklab &left, const Oklab &right) {
  return std::hypot(left.lightness - right.lightness,
                    left.greenRed - right.greenRed,
                    left.blueYellow - right.blueYellow);
}

qreal cross(const QPointF &origin, const QPointF &left, const QPointF &right) {
  return (left.x() - origin.x()) * (right.y() - origin.y()) -
         (left.y() - origin.y()) * (right.x() - origin.x());
}

QList<QPointF> convexHull(QList<QPointF> points) {
  std::sort(points.begin(), points.end(),
            [](const QPointF &left, const QPointF &right) {
              return left.x() < right.x() ||
                     (left.x() == right.x() && left.y() < right.y());
            });
  points.erase(std::unique(points.begin(), points.end()), points.end());
  if (points.size() <= 2) {
    return points;
  }
  QList<QPointF> result;
  result.reserve(points.size() * 2);
  for (const QPointF &point : points) {
    while (result.size() >= 2 &&
           cross(result.at(result.size() - 2), result.back(), point) <= 0.0) {
      result.removeLast();
    }
    result.append(point);
  }
  const qsizetype lowerSize = result.size();
  for (auto iterator = points.crbegin(); iterator != points.crend();
       ++iterator) {
    while (result.size() > lowerSize &&
           cross(result.at(result.size() - 2), result.back(), *iterator) <=
               0.0) {
      result.removeLast();
    }
    result.append(*iterator);
  }
  result.removeLast();
  return result;
}

qreal polygonArea(const QList<QPointF> &points) {
  if (points.size() < 3) {
    return 0.0;
  }
  qreal twiceArea = 0.0;
  for (int index = 0; index < points.size(); ++index) {
    const QPointF &current = points.at(index);
    const QPointF &next = points.at((index + 1) % points.size());
    twiceArea += current.x() * next.y() - current.y() * next.x();
  }
  return std::abs(twiceArea) / 2.0;
}

Metrics measure(const Icon &icon, const Config &config) {
  QImage sample(AnalysisPixels, AnalysisPixels,
                QImage::Format_ARGB32_Premultiplied);
  sample.fill(Qt::transparent);
  QPainter painter(&sample);
  painter.setRenderHint(QPainter::Antialiasing);
  painter.setRenderHint(QPainter::SmoothPixmapTransform);
  const QRectF keyline((AnalysisPixels - AnalysisKeyline) / 2.0,
                       (AnalysisPixels - AnalysisKeyline) / 2.0,
                       AnalysisKeyline, AnalysisKeyline);
  drawIcon(painter, keyline, icon, config.slot);
  painter.end();

  const qreal backgroundRed = linearChannel(config.background.red());
  const qreal backgroundGreen = linearChannel(config.background.green());
  const qreal backgroundBlue = linearChannel(config.background.blue());
  const Oklab background =
      toOklab(backgroundRed, backgroundGreen, backgroundBlue);
  qreal alphaX = 0.0;
  qreal alphaY = 0.0;
  qreal perceptualX = 0.0;
  qreal perceptualY = 0.0;
  qreal peakPerceptual = 0.0;
  std::vector<qreal> distances(sample.width() * sample.height());
  Metrics result;
  for (int y = 0; y < sample.height(); ++y) {
    for (int x = 0; x < sample.width(); ++x) {
      const QColor pixel = sample.pixelColor(x, y);
      const qreal alpha = pixel.alphaF();
      if (alpha <= 0.0) {
        continue;
      }
      const qreal red =
          alpha * linearChannel(pixel.red()) + (1.0 - alpha) * backgroundRed;
      const qreal green = alpha * linearChannel(pixel.green()) +
                          (1.0 - alpha) * backgroundGreen;
      const qreal blue =
          alpha * linearChannel(pixel.blue()) + (1.0 - alpha) * backgroundBlue;
      const qreal perceptual =
          colorDistance(toOklab(red, green, blue), background);
      distances[y * sample.width() + x] = perceptual;
      peakPerceptual = std::max(peakPerceptual, perceptual);
      result.alphaMass += alpha;
      result.perceptualMass += perceptual;
      alphaX += x * alpha;
      alphaY += y * alpha;
      perceptualX += x * perceptual;
      perceptualY += y * perceptual;
    }
  }
  if (result.alphaMass > 0.0) {
    result.alphaCentroid = {alphaX / result.alphaMass,
                            alphaY / result.alphaMass};
  }
  if (result.perceptualMass > 0.0) {
    result.perceptualCentroid = {perceptualX / result.perceptualMass,
                                 perceptualY / result.perceptualMass};
  }
  const qreal silhouetteThreshold = peakPerceptual * config.silhouetteFraction;
  QList<QPointF> envelopePoints;
  for (int y = 0; y < sample.height(); ++y) {
    int firstEnvelope = -1;
    int lastEnvelope = -1;
    for (int x = 0; x < sample.width(); ++x) {
      if (distances[y * sample.width() + x] >= silhouetteThreshold) {
        firstEnvelope = firstEnvelope < 0 ? x : firstEnvelope;
        lastEnvelope = x;
      }
    }
    if (firstEnvelope >= 0) {
      envelopePoints.append(QPointF(firstEnvelope + 0.5, y + 0.5));
      if (lastEnvelope != firstEnvelope) {
        envelopePoints.append(QPointF(lastEnvelope + 0.5, y + 0.5));
      }
    }
  }
  result.envelopeArea = polygonArea(convexHull(std::move(envelopePoints)));
  const QPointF center((AnalysisPixels - 1) / 2.0, (AnalysisPixels - 1) / 2.0);
  const qreal unitsPerPixel = config.slot / AnalysisKeyline;
  result.alphaCentroid = (result.alphaCentroid - center) * unitsPerPixel;
  result.perceptualCentroid =
      (result.perceptualCentroid - center) * unitsPerPixel;
  return result;
}

QSize logicalSheetSize(int columns, int rows) {
  return {static_cast<int>(Margin * 2.0 + RowLabelWidth + columns * CellWidth),
          static_cast<int>(Margin * 2.0 + HeaderHeight + rows * CellHeight)};
}

void drawProfile(QPainter &painter, const Config &config,
                 const Profile &profile, qreal top) {
  QFont label = painter.font();
  label.setPixelSize(15);
  label.setWeight(QFont::Medium);
  painter.setFont(label);
  painter.setPen(QColor("#dce3f4"));
  painter.drawText(QRectF(Margin, top, RowLabelWidth - 8.0, CellHeight),
                   Qt::AlignLeft | Qt::AlignVCenter, profile.name);

  for (int index = 0; index < config.icons.size(); ++index) {
    const Icon &icon = config.icons.at(index);
    const qreal size = profile.sizes.value(icon.name, config.slot);
    const QRectF panel(Margin + RowLabelWidth + index * CellWidth, top + 6.0,
                       CellWidth - 10.0, CellHeight - 12.0);
    painter.setPen(Qt::NoPen);
    painter.setBrush(config.background);
    painter.drawRoundedRect(panel, 8.0, 8.0);

    const QRectF zoomedSlot(panel.center().x() - config.slot * Zoom / 2.0,
                            panel.top() + 38.0, config.slot * Zoom,
                            config.slot * Zoom);
    painter.setBrush(Qt::NoBrush);
    painter.setPen(QPen(QColor("#58627b"), 1.0, Qt::DashLine));
    painter.drawRect(zoomedSlot);
    drawIcon(painter, centered(zoomedSlot, size * Zoom), icon, config.slot);

    QFont nameFont = painter.font();
    nameFont.setPixelSize(13);
    nameFont.setWeight(QFont::Normal);
    painter.setFont(nameFont);
    painter.setPen(QColor("#ffffff"));
    painter.drawText(QRectF(panel.left() + 6.0, panel.top() + 8.0,
                            panel.width() - 12.0, 20.0),
                     Qt::AlignCenter, icon.name);

    const QRectF actualSlot(panel.left() + 18.0, panel.bottom() - 44.0,
                            config.slot, config.slot);
    drawIcon(painter, centered(actualSlot, size), icon, config.slot);
    painter.setPen(QColor("#aeb8ce"));
    painter.drawText(QRectF(actualSlot.right() + 8.0, actualSlot.top(),
                            panel.right() - actualSlot.right() - 12.0,
                            actualSlot.height()),
                     Qt::AlignLeft | Qt::AlignVCenter,
                     QString("%1 px").arg(size, 0, 'f', 1));
  }
}

QImage render(const Config &config, const QList<Profile> &profiles,
              qreal uiScale) {
  const QSize logical = logicalSheetSize(config.icons.size(), profiles.size());
  const QSize pixels(std::lround(logical.width() * uiScale),
                     std::lround(logical.height() * uiScale));
  QImage image(pixels, QImage::Format_ARGB32_Premultiplied);
  image.setDevicePixelRatio(uiScale);
  image.fill(config.canvas);
  QPainter painter(&image);
  painter.setRenderHint(QPainter::Antialiasing);
  painter.setRenderHint(QPainter::SmoothPixmapTransform);
  QFont heading;
  heading.setPixelSize(17);
  heading.setWeight(QFont::Medium);
  painter.setFont(heading);
  painter.setPen(QColor("#dce3f4"));
  painter.drawText(QRectF(Margin, Margin, logical.width() - Margin * 2.0,
                          HeaderHeight - 8.0),
                   Qt::AlignLeft | Qt::AlignVCenter,
                   QString("%1 - anchor: %2, keyline: %3 px")
                       .arg(config.name, config.anchor)
                       .arg(config.slot, 0, 'f', 0));
  qreal top = Margin + HeaderHeight;
  for (const Profile &profile : profiles) {
    drawProfile(painter, config, profile, top);
    top += CellHeight;
  }
  return image;
}

QList<qreal> calibrationSizes(const Icon &icon, const Config &config) {
  const qreal minimum = icon.calibrationMinimum > 0.0 ? icon.calibrationMinimum
                                                      : config.minimumSize;
  const qreal maximum = icon.calibrationMaximum > 0.0 ? icon.calibrationMaximum
                                                      : config.maximumSize;
  QList<qreal> result;
  for (qreal size = minimum; size <= maximum + 0.001; size += 1.0) {
    result.append(size);
  }
  return result;
}

QImage renderCalibration(const Config &config, const Icon &anchor,
                         const Icon &peer, const QList<qreal> &sizes,
                         qreal uiScale) {
  constexpr qreal pairZoom = 2.5;
  constexpr qreal pairGap = 12.0;
  const qreal keyline = config.slot * pairZoom;
  const QSize logical(
      std::lround(Margin * 2.0 + sizes.size() * CalibrationCellWidth),
      std::lround(Margin * 2.0 + HeaderHeight + CellHeight));
  const QSize pixels(std::lround(logical.width() * uiScale),
                     std::lround(logical.height() * uiScale));
  QImage image(pixels, QImage::Format_ARGB32_Premultiplied);
  image.setDevicePixelRatio(uiScale);
  image.fill(config.canvas);
  QPainter painter(&image);
  painter.setRenderHint(QPainter::Antialiasing);
  painter.setRenderHint(QPainter::SmoothPixmapTransform);

  QFont heading;
  heading.setPixelSize(17);
  heading.setWeight(QFont::Medium);
  painter.setFont(heading);
  painter.setPen(QColor("#dce3f4"));
  painter.drawText(
      QRectF(Margin, Margin, logical.width() - Margin * 2.0,
             HeaderHeight - 8.0),
      Qt::AlignLeft | Qt::AlignVCenter,
      QString("%1 vs anchor %2 (%3 px)")
          .arg(peer.name, anchor.name)
          .arg(config.profiles.front().sizes.value(anchor.name, config.slot), 0,
               'f', 0));

  const qreal anchorSize =
      config.profiles.front().sizes.value(anchor.name, config.slot);
  for (int index = 0; index < sizes.size(); ++index) {
    const qreal size = sizes.at(index);
    const QRectF panel(Margin + index * CalibrationCellWidth,
                       Margin + HeaderHeight + 6.0, CalibrationCellWidth - 10.0,
                       CellHeight - 12.0);
    painter.setPen(Qt::NoPen);
    painter.setBrush(config.background);
    painter.drawRoundedRect(panel, 8.0, 8.0);

    QFont label = painter.font();
    label.setPixelSize(13);
    label.setWeight(QFont::Normal);
    painter.setFont(label);
    painter.setPen(QColor("#ffffff"));
    painter.drawText(QRectF(panel.left() + 6.0, panel.top() + 8.0,
                            panel.width() - 12.0, 20.0),
                     Qt::AlignCenter, QString("%1 px").arg(size, 0, 'f', 0));

    const qreal pairWidth = keyline * 2.0 + pairGap;
    const qreal pairLeft = panel.center().x() - pairWidth / 2.0;
    const QRectF anchorSlot(pairLeft, panel.top() + 38.0, keyline, keyline);
    const QRectF peerSlot(anchorSlot.right() + pairGap, anchorSlot.top(),
                          keyline, keyline);
    painter.setBrush(Qt::NoBrush);
    painter.setPen(QPen(QColor("#58627b"), 1.0, Qt::DashLine));
    painter.drawRect(anchorSlot);
    painter.drawRect(peerSlot);
    drawIcon(painter, centered(anchorSlot, anchorSize * pairZoom), anchor,
             config.slot);
    drawIcon(painter, centered(peerSlot, size * pairZoom), peer, config.slot);

    const qreal actualWidth = config.slot * 2.0 + 8.0;
    const qreal actualLeft = panel.center().x() - actualWidth / 2.0;
    const QRectF actualAnchor(actualLeft, panel.bottom() - 40.0, config.slot,
                              config.slot);
    const QRectF actualPeer(actualAnchor.right() + 8.0, actualAnchor.top(),
                            config.slot, config.slot);
    drawIcon(painter, centered(actualAnchor, anchorSize), anchor, config.slot);
    drawIcon(painter, centered(actualPeer, size), peer, config.slot);
  }
  return image;
}

bool saveImage(const QImage &image, const QString &path) {
  if (image.save(path)) {
    QTextStream(stdout) << path << '\n';
    return true;
  }
  qCritical("could not save preview: %s", qPrintable(path));
  return false;
}

bool saveMetrics(const Config &config, const QList<Metrics> &metrics,
                 const QList<Profile> &profiles, const QString &path) {
  QJsonArray icons;
  for (int index = 0; index < config.icons.size(); ++index) {
    const Icon &icon = config.icons.at(index);
    const Metrics &item = metrics.at(index);
    QJsonObject sizes;
    for (const Profile &profile : profiles) {
      sizes.insert(profile.name, profile.sizes.value(icon.name));
    }
    icons.append(QJsonObject{
        {"name", icon.name},
        {"display_bounds",
         QJsonArray{icon.displayBounds.x(), icon.displayBounds.y(),
                    icon.displayBounds.width(), icon.displayBounds.height()}},
        {"alpha_mass", item.alphaMass},
        {"perceptual_mass", item.perceptualMass},
        {"envelope_area", item.envelopeArea},
        {"alpha_centroid",
         QJsonArray{item.alphaCentroid.x(), item.alphaCentroid.y()}},
        {"perceptual_centroid",
         QJsonArray{item.perceptualCentroid.x(), item.perceptualCentroid.y()}},
        {"sizes", sizes},
    });
  }
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) ||
      file.write(QJsonDocument(QJsonObject{{"name", config.name},
                                           {"anchor", config.anchor},
                                           {"icons", icons}})
                     .toJson(QJsonDocument::Indented)) < 0) {
    qCritical("could not save metrics: %s", qPrintable(path));
    return false;
  }
  QTextStream(stdout) << path << '\n';
  return true;
}

} // namespace

int main(int argc, char *argv[]) {
  QGuiApplication app(argc, argv);
  QCoreApplication::setApplicationName("wfgui-icon-optics");

  QCommandLineParser parser;
  parser.setApplicationDescription(
      "Compare optical sizes for a configured icon set");
  parser.addHelpOption();
  const QCommandLineOption configOption(
      "config", "Read icon set from FILE.", "FILE",
      QDir(QString(WFCLI_SOURCE_DIR))
          .filePath("tools/icon-optics/foundry.json"));
  const QCommandLineOption outputDir(
      "output-dir", "Write previews under DIR.", "DIR",
      QDir(QString(WFCLI_SOURCE_DIR)).filePath("previews/optics"));
  const QCommandLineOption uiScale("ui-scale", "Render at UI scale FACTOR.",
                                   "FACTOR", "1.25");
  parser.addOptions({configOption, outputDir, uiScale});
  parser.process(app);

  bool scaleOk = false;
  const qreal scale = parser.value(uiScale).toDouble(&scaleOk);
  if (!scaleOk || scale < 0.5 || scale > 3.0) {
    qCritical("invalid --ui-scale (expected 0.5 through 3.0)");
    return 2;
  }
  auto config =
      loadConfig(QFileInfo(parser.value(configOption)).absoluteFilePath());
  if (!config) {
    return 1;
  }

  QList<Metrics> metrics;
  metrics.reserve(config->icons.size());
  for (const Icon &icon : config->icons) {
    metrics.append(measure(icon, *config));
  }
  const QList<Profile> profiles = config->profiles;

  const QString output = QFileInfo(parser.value(outputDir)).absoluteFilePath();
  if (!QDir().mkpath(output)) {
    qCritical("could not create output directory: %s", qPrintable(output));
    return 1;
  }
  const int percent = std::lround(scale * 100.0);
  bool ok = true;
  for (const Profile &profile : profiles) {
    const QString path =
        QDir(output).filePath(QString("%1-%2-%3.png")
                                  .arg(slug(config->name), slug(profile.name))
                                  .arg(percent));
    ok = saveImage(render(*config, {profile}, scale), path) && ok;
  }
  const QString comparison = QDir(output).filePath(
      QString("%1-comparison-%2.png").arg(slug(config->name)).arg(percent));
  ok = saveImage(render(*config, profiles, scale), comparison) && ok;
  const auto anchor = std::find_if(
      config->icons.cbegin(), config->icons.cend(),
      [&config](const Icon &icon) { return icon.name == config->anchor; });
  for (const Icon &icon : config->icons) {
    if (icon.name == config->anchor) {
      continue;
    }
    const QString calibration =
        QDir(output).filePath(QString("%1-%2-calibration-%3.png")
                                  .arg(slug(config->name), slug(icon.name))
                                  .arg(percent));
    ok = saveImage(renderCalibration(*config, *anchor, icon,
                                     calibrationSizes(icon, *config), scale),
                   calibration) &&
         ok;
  }
  ok = saveMetrics(*config, metrics, profiles,
                   QDir(output).filePath(
                       QString("%1-metrics.json").arg(slug(config->name)))) &&
       ok;
  return ok ? 0 : 1;
}
