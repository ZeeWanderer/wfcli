#include "display_scale.h"

#include <QByteArray>
#include <QSettings>
#include <QtGlobal>

namespace {
constexpr int MinimumScale = 25;
constexpr int MaximumScale = 175;
constexpr int ScaleStep = 25;

int normalizedScale(int percent) {
  const int clamped = qBound(MinimumScale, percent, MaximumScale);
  return ((clamped + ScaleStep / 2) / ScaleStep) * ScaleStep;
}
} // namespace

namespace wfgui {

int configuredUiScalePercent() {
  QSettings settings("wfcli", "wfgui");
  return normalizedScale(settings.value("ui/scale_percent", 100).toInt());
}

void setConfiguredUiScalePercent(int percent) {
  QSettings settings("wfcli", "wfgui");
  settings.setValue("ui/scale_percent", normalizedScale(percent));
}

void applyConfiguredUiScale() {
  const double factor = configuredUiScalePercent() / 100.0;
  qputenv("QT_SCALE_FACTOR", QByteArray::number(factor, 'f', 2));
}

} // namespace wfgui
