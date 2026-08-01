#include <QApplication>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QIcon>
#include <QPixmapCache>
#include <QTimer>

#include "main_window.h"
#include "display_scale.h"

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
  const QCommandLineOption page(
      "page", "Open foundry, mastery, inventory, or relic.", "NAME", "foundry");
  parser.addOptions({screenshot, size, screenshotDelay, page});
  parser.process(app);

  QFile style(":/resources/style.qss");
  if (style.open(QIODevice::ReadOnly)) {
    app.setStyleSheet(QString::fromUtf8(style.readAll()));
  }

  MainWindow window;
  if (!window.setPage(parser.value(page))) {
    qCritical("invalid --page (use foundry, mastery, inventory, or relic)");
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

  if (parser.isSet(screenshot)) {
    bool delayOk = false;
    const int delay = parser.value(screenshotDelay).toInt(&delayOk);
    if (!delayOk || delay < 0) {
      qCritical("invalid --screenshot-delay");
      return 2;
    }
    const QString path = QFileInfo(parser.value(screenshot)).absoluteFilePath();
    QDir().mkpath(QFileInfo(path).absolutePath());
    QTimer::singleShot(delay, &window, [&app, &window, path] {
      if (!window.grab().save(path)) {
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
