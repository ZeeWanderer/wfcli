#pragma once

#include <QJsonObject>
#include <QWidget>

#include <functional>

struct MarketOrderCardActions {
  std::function<void()> visibility;
  std::function<void()> edit;
  std::function<void()> add;
  std::function<void()> close;
  std::function<void()> remove;
  std::function<void()> listings;
};

class MarketOrderCard final : public QWidget {
public:
  MarketOrderCard(const QJsonObject &order, const QJsonObject &item,
                  const QJsonObject &quote, int owned,
                  MarketOrderCardActions actions, QWidget *parent = nullptr);
};
