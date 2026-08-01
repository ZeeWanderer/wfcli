#pragma once

#include <QWidget>

class AppController;
class QButtonGroup;
class QLabel;
class QProgressBar;
class QPushButton;
class QStackedLayout;
class RelicGridWidget;

class RelicPlannerWidget final : public QWidget {
  Q_OBJECT

public:
  explicit RelicPlannerWidget(AppController *controller,
                              QWidget *parent = nullptr);

private:
  void updateContent();
  void updateEra();
  void updateEraIcons();

  AppController *controller_;
  QLabel *traceCount_;
  QProgressBar *priceProgress_;
  QLabel *emptyState_;
  RelicGridWidget *relics_;
  QPushButton *refresh_;
  QButtonGroup *eraGroup_;
  QStackedLayout *content_;
};
