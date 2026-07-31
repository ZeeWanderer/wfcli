#pragma once

#include <QGuiApplication>
#include <QScreen>
#include <QWidget>
#include <QtMath>

namespace wfgui {

inline qreal displayScale(const QWidget *widget) {
  const QScreen *screen =
      widget ? widget->screen() : QGuiApplication::primaryScreen();
  if (!screen || screen->devicePixelRatio() > 1.05 ||
      screen->geometry().height() < 1300) {
    return 1.0;
  }
  return 1.125;
}

inline int scaled(int value, qreal scale) { return qRound(value * scale); }

} // namespace wfgui
