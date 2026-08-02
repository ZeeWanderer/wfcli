#pragma once

#include <QDialog>
#include <QJsonObject>
#include <QList>
#include <QString>

class AppController;
class QLabel;
class QButtonGroup;
class QComboBox;
class QProgressBar;
class QPushButton;
class QSpinBox;
class QTableWidget;
class QTimer;
class QWidget;

class MarketItemDialog final : public QDialog {
  Q_OBJECT

public:
  explicit MarketItemDialog(AppController *controller,
                            QWidget *parent = nullptr);
  void showItem(const QString &item, const QString &side = QString());

signals:
  void signInRequested();

private:
  void setMode(const QString &side);
  void updateContent();
  void updateListings(const QJsonArray &orders);
  void updatePostingFields(const QJsonObject &item);
  void requestData(bool refresh);
  void requestVariantData(bool refresh = false);
  void copyWhisper();
  void postOrder();
  QJsonObject postingFilters() const;
  QString listingPlayer(const QJsonObject &order) const;

  AppController *controller_;
  QLabel *image_;
  QLabel *name_;
  QLabel *status_;
  QButtonGroup *modes_;
  QTableWidget *listings_;
  QProgressBar *progress_;
  QSpinBox *quantity_;
  QSpinBox *price_;
  QSpinBox *rank_;
  QSpinBox *charges_;
  QSpinBox *amberStars_;
  QSpinBox *cyanStars_;
  QSpinBox *perTrade_;
  QComboBox *subtype_;
  QWidget *rankRow_;
  QWidget *chargesRow_;
  QWidget *amberStarsRow_;
  QWidget *cyanStarsRow_;
  QWidget *perTradeRow_;
  QWidget *subtypeRow_;
  QTimer *variantTimer_;
  QPushButton *copy_;
  QPushButton *post_;
  QPushButton *signIn_;
  QList<QJsonObject> listingRows_;
  QString itemKey_;
  QJsonObject variantQuote_;
  QJsonObject variantQuoteFilters_;
  QString mode_ = "sell";
  bool posting_ = false;
  bool initializePrice_ = true;
};
