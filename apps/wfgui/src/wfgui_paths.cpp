#include "wfgui_paths.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QStandardPaths>

namespace {
QJsonObject pathEntry(const char *kind, const QString &path) {
  return {{"kind", kind}, {"path", QFileInfo(path).absoluteFilePath()}};
}
} // namespace

namespace wfgui {

QString cacheDirectory() {
  return QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
}

QString derivativeCacheDirectory() {
  return QDir(cacheDirectory()).filePath("derivatives/v1");
}

QString daemonSocketPath() {
  const QString configured = qEnvironmentVariable("WFCLI_DAEMON_SOCKET");
  if (!configured.isEmpty()) {
    return configured;
  }
  const QString runtime =
      QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
  if (!runtime.isEmpty()) {
    return QDir(runtime).filePath("wfcli/wfdaemon.sock");
  }
  return QDir(QStandardPaths::writableLocation(
                  QStandardPaths::GenericCacheLocation))
      .filePath("wfcli/wfdaemon.sock");
}

QByteArray pathReportJson() {
  const QSettings settings("wfcli", "wfgui");
  const QJsonArray paths{
      pathEntry("config", QFileInfo(settings.fileName()).absolutePath()),
      pathEntry("cache", cacheDirectory()),
      pathEntry("derivatives", derivativeCacheDirectory()),
      pathEntry("runtime", QFileInfo(daemonSocketPath()).absolutePath()),
  };
  return QJsonDocument(QJsonObject{{"app", "wfgui"}, {"paths", paths}})
      .toJson(QJsonDocument::Compact);
}

} // namespace wfgui
