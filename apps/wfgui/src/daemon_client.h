#pragma once

#include <QByteArray>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QProcess>
#include <QSet>
#include <QString>
#include <QStringList>

#include <optional>

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
  void requestNotificationSettings();
  void setFissureNotificationMode(const QString &mode);
  void requestAssets(const QJsonArray &assets);
  void requestAssetCacheStatus();
  void clearAssetCache();
  void requestMarketQuotes(const QStringList &items, bool refresh = false);
  void requestMarketVariantQuote(const QString &item,
                                 const QJsonObject &filters,
                                 bool refresh = false);
  void requestMarketMatches(const QString &query, int limit = 5);
  void requestMarketItems(const QStringList &items);
  void requestMarketAccount();
  void marketLogin(const QString &email, const QString &password);
  void marketLogout();
  void marketCreateOrder(const QJsonObject &order);
  void marketUpdateOrder(const QString &id, const QJsonObject &patch);
  void marketDeleteOrder(const QString &id);
  void marketCloseOrder(const QString &id, int quantity);
  void setMarketOrdersVisible(bool visible, const QString &type = QString());
  void setMarketPresenceMode(const QString &mode);

signals:
  void connectionChanged();
  void statusChanged();
  void relicPlannerReady(const QString &era, bool prices,
                         const QJsonObject &data);
  void playerViewReady(const QString &view, const QJsonObject &data);
  void playerViewFailed(const QString &view, const QString &error);
  void activityReady(const QJsonObject &data);
  void activityFailed(const QString &error);
  void notificationSettingsReady(const QJsonObject &settings);
  void notificationSettingsFailed(const QString &error);
  void assetsResolved(const QJsonArray &assets);
  void assetRequestFailed(const QString &error);
  void assetCacheStatusReady(const QJsonObject &status);
  void assetCacheRequestFailed(const QString &error);
  void marketQuotesResolved(const QJsonArray &quotes,
                            const QJsonArray &missing);
  void marketQuoteRequestFailed(const QStringList &items, const QString &error);
  void marketVariantQuoteReady(const QString &item, const QJsonObject &filters,
                               const QJsonObject &data);
  void marketVariantQuoteFailed(const QString &item, const QJsonObject &filters,
                                const QString &error);
  void marketMatchesResolved(const QString &query, const QJsonArray &matches);
  void marketMatchesFailed(const QString &query, const QString &error);
  void marketItemsDescribed(const QJsonArray &items, const QJsonArray &missing);
  void marketItemDescribeFailed(const QStringList &items, const QString &error);
  void marketAccountReady(const QString &action, const QJsonObject &account);
  void marketAccountFailed(const QString &action, const QString &error);
  void marketPresenceReady(const QJsonObject &presence, bool requested);
  void marketPresenceFailed(const QString &error);
  void requestFailed(const QString &era, bool prices, const QString &error);

private:
  void connectSocket();
  void ensureDaemon(bool update = false);
  void handleLine(const QByteArray &line);
  void sendHello();
  void sendPendingRequests();
  void sendPendingPlayerViews();
  void sendPendingActivity();
  void sendPendingNotificationSettings();
  void sendPendingAssets();
  void sendPendingAssetCacheRequest();
  void sendAssetBatch(const QJsonArray &assets);
  void sendPendingMarketQuotes();
  void sendPendingMarketVariantQuotes();
  void sendPendingMarketResolve();
  void sendPendingMarketDescriptions();
  void sendPendingMarketAccount();
  void queueMarketAccountRequest(const QString &action,
                                 const QJsonObject &message);
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

  struct MarketAccountRequest {
    QString action;
    QJsonObject message;
  };

  struct MarketVariantRequest {
    QString item;
    QJsonObject filters;
    bool refresh = false;
  };

  struct MarketResolveRequest {
    QString query;
    int limit = 5;
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
  qint64 activeNotificationSettingsRequest_ = 0;
  QHash<QString, QJsonObject> pendingAssets_;
  QStringList pendingAssetOrder_;
  QHash<qint64, QJsonArray> activeAssetRequests_;
  qint64 activeAssetCacheRequest_ = 0;
  bool activeAssetCacheClear_ = false;
  QSet<QString> marketCacheRequested_;
  QSet<QString> pendingMarketCacheQuotes_;
  QStringList pendingMarketCacheQuoteOrder_;
  QHash<QString, bool> pendingMarketQuotes_;
  QStringList pendingMarketQuoteOrder_;
  QHash<qint64, MarketQuoteRequest> activeMarketQuoteRequests_;
  QList<MarketVariantRequest> pendingMarketVariantRequests_;
  QHash<qint64, MarketVariantRequest> activeMarketVariantRequests_;
  std::optional<MarketResolveRequest> pendingMarketResolve_;
  QHash<qint64, MarketResolveRequest> activeMarketResolveRequests_;
  QSet<QString> pendingMarketDescriptions_;
  QStringList pendingMarketDescriptionOrder_;
  QHash<qint64, QStringList> activeMarketDescriptionRequests_;
  QList<MarketAccountRequest> pendingMarketAccountRequests_;
  QHash<qint64, QString> activeMarketAccountRequests_;
  bool ready_ = false;
  bool pendingActivity_ = false;
  bool pendingAssetCacheStatus_ = false;
  bool pendingAssetCacheClear_ = false;
  bool pendingNotificationSettings_ = true;
  bool pendingMarketAccountSnapshot_ = true;
  bool activeNotificationRequestIsSet_ = false;
  std::optional<QString> desiredNotificationMode_;
  std::optional<QString> sentNotificationMode_;
  bool connected_ = false;
  bool ensureAttempted_ = false;
  bool updateAttempted_ = false;
  bool stopAttempted_ = false;
  bool updatingDaemon_ = false;
  bool stoppingDaemon_ = false;
  qint64 nextRequestId_ = 10;
  QString status_ = "Connecting to wfdaemon";
};
