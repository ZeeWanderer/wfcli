#include "display_scale.h"

#include <QByteArray>
#include <QSettings>
#include <QtGlobal>

namespace wfgui {

int normalizedUiScalePercent(int percent) {
  const int clamped =
      qBound(MinimumUiScalePercent, percent, MaximumUiScalePercent);
  return ((clamped + UiScaleStepPercent / 2) / UiScaleStepPercent) *
         UiScaleStepPercent;
}

int configuredUiScalePercent() {
  QSettings settings("wfcli", "wfgui");
  return normalizedUiScalePercent(
      settings.value("ui/scale_percent", 100).toInt());
}

void setConfiguredUiScalePercent(int percent) {
  QSettings settings("wfcli", "wfgui");
  settings.setValue("ui/scale_percent", normalizedUiScalePercent(percent));
}

void applyConfiguredUiScale() {
  const double factor = configuredUiScalePercent() / 100.0;
  qputenv("QT_SCALE_FACTOR", QByteArray::number(factor, 'f', 2));
}

} // namespace wfgui
