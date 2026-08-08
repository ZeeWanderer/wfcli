#pragma once

#include <QByteArray>
#include <QString>

namespace wfgui {

QString cacheDirectory();
QString derivativeCacheDirectory();
QString daemonSocketPath();
QByteArray pathReportJson();

} // namespace wfgui
