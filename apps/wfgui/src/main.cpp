#include <QApplication>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QIcon>
#include <QPixmapCache>
#include <QTextStream>
#include <QTimer>

#include "display_scale.h"
#include "main_window.h"
#include "style_loader.h"
#include "widget_capture.h"

#include <cstdlib>

namespace {
QSize parseSize(const QString &value) {
  const QStringList parts = value.toLower().split('x');
  bool widthOk = false;
  bool heightOk = false;
  const int width = parts.value(0).toInt(&widthOk);
  const int height = parts.value(1).toInt(&heightOk);
  return parts.size() == 2 && widthOk && heightOk && width > 0 && height > 0
             ? QSize(width, height)
             : QSize{};
}
} // namespace

int main(int argc, char *argv[]) {
  QCoreApplication::setOrganizationName("wfcli");
  QCoreApplication::setApplicationName("wfgui");
  QGuiApplication::setDesktopFileName("wfgui");
  wfgui::applyConfiguredUiScale();
  QApplication app(argc, argv);
  app.setWindowIcon(QIcon(":/resources/ui/nav_mastery.png"));
  QFontDatabase::addApplicationFont(":/assets/Roboto-Bold.ttf");
  QFontDatabase::addApplicationFont(":/assets/Roboto-Light.ttf");
  QFontDatabase::addApplicationFont(":/assets/Roboto-Medium.ttf");
  QFontDatabase::addApplicationFont(":/assets/Roboto-Regular.ttf");
  QPixmapCache::setCacheLimit(64 * 1024);
  QCoreApplication::setApplicationVersion(WFCLI_VERSION);

  QCommandLineParser parser;
  parser.setApplicationDescription("wfcli desktop client");
  parser.addHelpOption();
  parser.addVersionOption();
  const QCommandLineOption screenshot(
      "screenshot", "Save this window to FILE after startup.", "FILE");
  const QCommandLineOption size("size", "Set window size to WIDTHxHEIGHT.",
                                "WIDTHxHEIGHT");
  const QCommandLineOption screenshotDelay(
      "screenshot-delay", "Wait MS before saving a screenshot.", "MS", "8000");
  const QCommandLineOption capture(
      "capture", "Capture named UI target instead of the whole window.",
      "NAME");
  const QCommandLineOption capturePadding(
      "capture-padding",
      "Include PX of surrounding UI around a capture target.", "PX", "0");
  const QCommandLineOption listCaptureTargets(
      "list-capture-targets", "List named UI capture targets and exit.");
  const QCommandLineOption page(
      "page", "Open foundry, mastery, inventory, relic, or market.", "NAME",
      "foundry");
  const QCommandLineOption marketItem("market-item",
                                      "Open Market listings for ITEM.", "ITEM");
  const QCommandLineOption marketSide(
      "market-side", "Show sell or buy listings.", "SIDE", "sell");
  const QCommandLineOption activityTab(
      "activity-tab", "Open timers or market in the right rail.", "NAME",
      "timers");
  parser.addOptions({screenshot, size, screenshotDelay, capture, capturePadding,
                     listCaptureTargets, page, marketItem, marketSide,
                     activityTab});
  parser.process(app);

  if (parser.isSet(capture) && !parser.isSet(screenshot)) {
    qCritical("--capture requires --screenshot");
    return 2;
  }

  app.setStyleSheet(wfgui::applicationStyleSheet());

  MainWindow window;
  if (!window.setPage(parser.value(page))) {
    qCritical(
        "invalid --page (use foundry, mastery, inventory, relic, or market)");
    return 2;
  }
  if (parser.isSet(size)) {
    const QSize requested = parseSize(parser.value(size));
    if (!requested.isValid()) {
      qCritical("invalid --size (use WIDTHxHEIGHT)");
      return 2;
    }
    window.resize(requested);
  }
  window.show();
  if (!window.setActivityTab(parser.value(activityTab))) {
    qCritical("invalid --activity-tab (use timers or market)");
    return 2;
  }
  if (parser.isSet(marketItem)) {
    const QString side = parser.value(marketSide).toLower();
    if (side != "sell" && side != "buy") {
      qCritical("invalid --market-side (use sell or buy)");
      return 2;
    }
    window.showMarketItem(parser.value(marketItem), side);
  }

  if (parser.isSet(listCaptureTargets)) {
    QTextStream output(stdout);
    for (const QString &name : wfgui::captureTargetNames()) {
      output << name << '\n';
    }
    return 0;
  }

  if (parser.isSet(screenshot)) {
    bool delayOk = false;
    const int delay = parser.value(screenshotDelay).toInt(&delayOk);
    if (!delayOk || delay < 0) {
      qCritical("invalid --screenshot-delay");
      return 2;
    }
    bool paddingOk = false;
    const int padding = parser.value(capturePadding).toInt(&paddingOk);
    if (!paddingOk || padding < 0) {
      qCritical("invalid --capture-padding");
      return 2;
    }
    const QString path = QFileInfo(parser.value(screenshot)).absoluteFilePath();
    const QString captureName = parser.value(capture);
    QDir().mkpath(QFileInfo(path).absolutePath());
    QTimer::singleShot(
        delay, &window, [&app, &window, path, captureName, padding] {
          QString error;
          const QPixmap image =
              captureName.isEmpty()
                  ? window.screenshotTarget()->grab()
                  : wfgui::grabCaptureTarget(captureName, padding, &error);
          if (image.isNull()) {
            qCritical("could not capture UI: %s", qPrintable(error));
            app.exit(2);
            return;
          }
          if (!image.save(path)) {
            qCritical("could not save screenshot: %s", qPrintable(path));
            app.exit(2);
            return;
          }
          qInfo("saved screenshot: %s", qPrintable(path));
          app.quit();
        });
  }
  return app.exec();
}
