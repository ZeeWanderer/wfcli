#include "market_order_card.h"

#include <QGraphicsOpacityEffect>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QIcon>
#include <QLabel>
#include <QPixmap>
#include <QSizePolicy>
#include <QToolButton>
#include <QVBoxLayout>

#include <initializer_list>
#include <utility>

#include "widget_capture.h"

namespace {
int firstInt(const QJsonObject &object,
             std::initializer_list<const char *> keys, int fallback = 0) {
  for (const char *key : keys) {
    if (object.value(key).isDouble()) {
      return object.value(key).toInt();
    }
  }
  return fallback;
}

QString extraOrderData(const QJsonObject &order) {
  QStringList values;
  const QString subtype = order.value("subtype").toString();
  if (!subtype.isEmpty()) {
    values.append(subtype.left(1).toUpper() + subtype.mid(1));
  }
  if (order.value("rank").isDouble()) {
    values.append(QString("Rank %1").arg(order.value("rank").toInt()));
  }
  if (order.value("charges").isDouble()) {
    values.append(QString("%1 charges").arg(order.value("charges").toInt()));
  }
  if (order.value("amberStars").isDouble()) {
    values.append(QString("%1 amber").arg(order.value("amberStars").toInt()));
  }
  if (order.value("cyanStars").isDouble()) {
    values.append(QString("%1 cyan").arg(order.value("cyanStars").toInt()));
  }
  const int perTrade = firstInt(order, {"perTrade", "per_trade"}, 1);
  if (perTrade > 1) {
    values.append(QString("%1 per trade").arg(perTrade));
  }
  return values.join(" · ");
}

QLabel *iconLabel(const QString &path, const QSize &size, QWidget *parent) {
  auto *label = new QLabel(parent);
  label->setFixedSize(size);
  label->setAlignment(Qt::AlignCenter);
  label->setPixmap(QPixmap(path).scaled(size, Qt::KeepAspectRatio,
                                        Qt::SmoothTransformation));
  return label;
}

QWidget *metricCell(const QString &value, const QString &iconPath,
                    const QSize &iconSize, QWidget *parent) {
  auto *cell = new QWidget(parent);
  cell->setObjectName("marketMetric");
  auto *layout = new QHBoxLayout(cell);
  layout->setContentsMargins(0, 0, 0, 0);
  layout->setSpacing(5);
  layout->setAlignment(Qt::AlignCenter);
  auto *text = new QLabel(value, cell);
  text->setObjectName("marketMetricText");
  layout->addWidget(text);
  layout->addWidget(iconLabel(iconPath, iconSize, cell));
  return cell;
}

QToolButton *actionButton(const char *name, const QString &iconPath,
                          const QString &tooltip,
                          const std::function<void()> &action,
                          QWidget *parent) {
  auto *button = new QToolButton(parent);
  button->setObjectName(name);
  button->setProperty("marketAction", true);
  button->setFixedSize(28, 28);
  button->setIcon(QIcon(iconPath));
  button->setIconSize(QSize(21, 21));
  button->setToolTip(tooltip);
  QObject::connect(button, &QToolButton::clicked, button, action);
  return button;
}
} // namespace

MarketOrderCard::MarketOrderCard(const QJsonObject &order,
                                 const QJsonObject &item,
                                 const QJsonObject &quote, int owned,
                                 MarketOrderCardActions actions,
                                 QWidget *parent)
    : QWidget(parent) {
  const bool visible = order.value("visible").toBool();
  const bool selling = order.value("type").toString() == "sell";
  const int quantity = order.value("quantity").toInt(1);

  setObjectName("marketOrderCard");
  wfgui::setCaptureItem(this);
  setMinimumWidth(370);
  setFixedHeight(107);
  setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);

  auto *root = new QVBoxLayout(this);
  root->setContentsMargins(0, 0, 0, 0);
  root->setSpacing(0);

  auto *top = new QWidget(this);
  top->setObjectName("marketOrderTop");
  top->setFixedHeight(28);
  auto *topLayout = new QHBoxLayout(top);
  topLayout->setContentsMargins(0, 0, 7, 0);
  topLayout->setSpacing(0);

  auto *visibility = new QToolButton(top);
  visibility->setObjectName("marketVisibility");
  visibility->setFixedSize(37, 28);
  visibility->setCheckable(true);
  QIcon visibilityIcon;
  visibilityIcon.addFile(":/resources/market/wfgui-eye-off.png", QSize(),
                         QIcon::Normal, QIcon::Off);
  visibilityIcon.addFile(":/resources/market/wfgui-eye.png", QSize(),
                         QIcon::Normal, QIcon::On);
  visibility->setIcon(visibilityIcon);
  visibility->setIconSize(QSize(20, 20));
  visibility->setChecked(visible);
  visibility->setToolTip(visible ? "Public order" : "Hidden order");
  topLayout->addWidget(visibility);

  auto *name =
      new QLabel(item.value("name").toString(item.isEmpty() ? "Loading item..."
                                                            : "Unknown item"),
                 top);
  name->setObjectName("marketOrderName");
  name->setTextInteractionFlags(Qt::TextSelectableByMouse);
  topLayout->addWidget(name, 1);

  auto *ownedLabel =
      new QLabel(owned >= 0 ? QString("%1 owned").arg(owned) : "-- owned", top);
  ownedLabel->setObjectName("marketOrderOwned");
  topLayout->addWidget(ownedLabel);
  if (selling && owned >= 0 && owned < quantity) {
    auto *warning = new QLabel("!", top);
    warning->setObjectName("marketWarning");
    warning->setAlignment(Qt::AlignCenter);
    warning->setFixedSize(37, 28);
    warning->setToolTip("Order quantity exceeds owned quantity");
    topLayout->addWidget(warning);
  }
  root->addWidget(top);

  auto *body = new QWidget(this);
  body->setObjectName("marketOrderBody");
  body->setProperty("private", !visible);
  body->setFixedHeight(79);
  if (!visible) {
    auto *opacity = new QGraphicsOpacityEffect(body);
    opacity->setOpacity(0.6);
    body->setGraphicsEffect(opacity);
  }
  auto *bodyLayout = new QHBoxLayout(body);
  bodyLayout->setContentsMargins(0, 0, 9, 0);
  bodyLayout->setSpacing(0);

  auto *art = new QWidget(body);
  art->setObjectName("marketOrderArt");
  art->setFixedWidth(70);
  auto *artLayout = new QVBoxLayout(art);
  artLayout->setContentsMargins(0, 2, 0, 4);
  artLayout->setSpacing(0);
  auto *image = new QLabel(art);
  image->setObjectName("marketOrderImage");
  image->setAlignment(Qt::AlignCenter);
  const QString path = item.value("asset_path").toString();
  if (!path.isEmpty()) {
    image->setPixmap(QPixmap(path).scaled(44, 44, Qt::KeepAspectRatio,
                                          Qt::SmoothTransformation));
  }
  artLayout->addWidget(image, 1);
  auto *side = new QLabel(selling ? "WTS" : "WTB", art);
  side->setObjectName(selling ? "marketSellBadge" : "marketBuyBadge");
  side->setAlignment(Qt::AlignCenter);
  side->setFixedSize(46, 20);
  artLayout->addWidget(side, 0, Qt::AlignHCenter);
  bodyLayout->addWidget(art);

  auto *details = new QWidget(body);
  details->setObjectName("marketOrderDetails");
  auto *grid = new QGridLayout(details);
  grid->setContentsMargins(5, 0, 0, 0);
  grid->setHorizontalSpacing(0);
  grid->setVerticalSpacing(0);
  for (int column = 0; column < 3; ++column) {
    grid->setColumnStretch(column, 1);
  }
  grid->setRowStretch(0, 1);
  grid->setRowStretch(1, 1);

  grid->addWidget(metricCell(QString::number(quantity),
                             ":/resources/market/wfgui-boxes.png",
                             QSize(20, 20), details),
                  0, 0);
  grid->addWidget(metricCell(QString::number(order.value("platinum").toInt()),
                             ":/assets/platinum.png", QSize(20, 18), details),
                  0, 1);
  auto *extra = new QLabel(extraOrderData(order), details);
  extra->setObjectName("marketOrderExtra");
  extra->setAlignment(Qt::AlignCenter);
  grid->addWidget(extra, 0, 2);

  auto *lowest = new QWidget(details);
  lowest->setObjectName("marketLowestPrice");
  auto *lowestLayout = new QHBoxLayout(lowest);
  lowestLayout->setContentsMargins(0, 0, 0, 3);
  lowestLayout->setSpacing(4);
  lowestLayout->setAlignment(Qt::AlignCenter);
  lowestLayout->addWidget(
      actionButton("marketListings", ":/resources/market/wfgui-search.png",
                   "Open listings", actions.listings, lowest));
  auto *lowestTitle =
      new QLabel(selling ? "Lowest price:" : "Highest price:", lowest);
  lowestTitle->setObjectName("marketLowestLabel");
  lowestLayout->addWidget(lowestTitle);
  const QJsonObject publicQuote = quote.value("quote").toObject();
  const QJsonValue comparison =
      publicQuote.value(selling ? "lowest_sell" : "highest_buy");
  auto *lowestValue = new QLabel(
      comparison.isDouble() ? QString::number(comparison.toInt()) : "-",
      lowest);
  lowestValue->setObjectName("marketMetricText");
  lowestLayout->addWidget(lowestValue);
  lowestLayout->addWidget(
      iconLabel(":/assets/platinum.png", QSize(20, 18), lowest));
  grid->addWidget(lowest, 1, 0, 1, 2);

  auto *buttons = new QWidget(details);
  buttons->setObjectName("marketOrderActions");
  auto *buttonLayout = new QHBoxLayout(buttons);
  buttonLayout->setContentsMargins(11, 0, 11, 3);
  buttonLayout->setSpacing(2);
  buttonLayout->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
  buttonLayout->addWidget(actionButton("marketEdit",
                                       ":/resources/market/wfgui-pencil.png",
                                       "Edit order", actions.edit, buttons));
  auto *add = actionButton("marketAdd", ":/resources/market/wfgui-plus.png",
                           "Add one trade unit", actions.add, buttons);
  add->setIconSize(QSize(28, 28));
  buttonLayout->addWidget(add);
  buttonLayout->addWidget(
      actionButton("marketSold", ":/resources/market/wfgui-check.png",
                   "Mark one sold", actions.close, buttons));
  buttonLayout->addWidget(
      actionButton("marketDelete", ":/resources/market/wfgui-trash.png",
                   "Delete order", actions.remove, buttons));
  grid->addWidget(buttons, 1, 2);

  bodyLayout->addWidget(details, 1);
  root->addWidget(body);

  connect(visibility, &QToolButton::clicked, this,
          [action = std::move(actions.visibility)] { action(); });
}
