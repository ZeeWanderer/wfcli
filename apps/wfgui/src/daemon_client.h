#pragma once

#include <QByteArray>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QSet>
#include <QString>
#include <QStringList>

class QLocalSocket;
class QTimer;

class DaemonClient final : public QObject {
  Q_OBJECT

public:
  explicit DaemonClient(QObject *parent = nullptr);

  bool connected() const;
  QString status() const;

  void start();
  void requestRelics(const QString &era, bool fetchPrices);
  void requestPlayerView(const QString &view);
  void requestActivity();
  void requestAssets(const QJsonArray &assets);
  void requestMarketQuotes(const QStringList &items, bool refresh = false);

signals:
  void connectionChanged();
  void statusChanged();
  void relicPlannerReady(const QString &era, bool prices,
                         const QJsonObject &data);
  void playerViewReady(const QString &view, const QJsonObject &data);
  void playerViewFailed(const QString &view, const QString &error);
  void activityReady(const QJsonObject &data);
  void activityFailed(const QString &error);
  void assetsResolved(const QJsonArray &assets);
  void assetRequestFailed(const QString &error);
  void marketQuotesResolved(const QJsonArray &quotes,
                            const QJsonArray &missing);
  void marketQuoteRequestFailed(const QStringList &items, const QString &error);
  void requestFailed(const QString &era, bool prices, const QString &error);

private:
  void connectSocket();
  void ensureDaemon(bool update = false);
  void handleLine(const QByteArray &line);
  void sendHello();
  void sendPendingRequests();
  void sendPendingPlayerViews();
  void sendPendingActivity();
  void sendPendingAssets();
  void sendAssetBatch(const QJsonArray &assets);
  void sendPendingMarketQuotes();
  void write(const QJsonObject &message);
  void setConnected(bool connected);
  void setStatus(const QString &status);
  QString socketPath() const;
  QString wfcliCommand() const;

  struct RelicRequest {
    QString era;
    bool prices = false;
  };

  struct MarketQuoteRequest {
    QStringList items;
    bool refresh = false;
    bool cacheOnly = false;
  };

  static QString relicRequestKey(const RelicRequest &request);
  bool relicRequestActive(const QString &key) const;
  bool assetRequestActive(const QString &id) const;
  bool marketQuoteActive(const QString &item, bool cacheOnly) const;

  QLocalSocket *socket_;
  QTimer *reconnectTimer_;
  QProcess ensureProcess_;
  QByteArray input_;
  QHash<QString, RelicRequest> pendingRelicRequests_;
  QHash<qint64, RelicRequest> activeRelicRequests_;
  QSet<QString> pendingPlayerViews_;
  QHash<qint64, QString> activePlayerViews_;
  qint64 activeActivityRequest_ = 0;
  QHash<QString, QJsonObject> pendingAssets_;
  QStringList pendingAssetOrder_;
  QHash<qint64, QJsonArray> activeAssetRequests_;
  QSet<QString> marketCacheRequested_;
  QSet<QString> pendingMarketCacheQuotes_;
  QStringList pendingMarketCacheQuoteOrder_;
  QHash<QString, bool> pendingMarketQuotes_;
  QStringList pendingMarketQuoteOrder_;
  QHash<qint64, MarketQuoteRequest> activeMarketQuoteRequests_;
  bool ready_ = false;
  bool pendingActivity_ = false;
  bool connected_ = false;
  bool ensureAttempted_ = false;
  bool updateAttempted_ = false;
  bool updatingDaemon_ = false;
  qint64 nextRequestId_ = 10;
  QString status_ = "Connecting to wfdaemon";
};
