#include "market_item_dialog.h"

#include <QAbstractItemView>
#include <QApplication>
#include <QButtonGroup>
#include <QClipboard>
#include <QComboBox>
#include <QFormLayout>
#include <QGridLayout>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QProgressBar>
#include <QPushButton>
#include <QPixmap>
#include <QSignalBlocker>
#include <QSpinBox>
#include <QTableWidget>
#include <QTableWidgetItem>
#include <QTimer>
#include <QVBoxLayout>

#include "app_controller.h"

namespace {
QString stringValue(const QJsonObject &object,
                    std::initializer_list<const char *> keys) {
  for (const char *key : keys) {
    const QString value = object.value(key).toString();
    if (!value.isEmpty()) {
      return value;
    }
  }
  return {};
}

int intValue(const QJsonObject &object,
             std::initializer_list<const char *> keys, int fallback = 0) {
  for (const char *key : keys) {
    if (object.value(key).isDouble()) {
      return object.value(key).toInt();
    }
  }
  return fallback;
}

QWidget *formRow(const QString &label, QWidget *field) {
  auto *row = new QWidget;
  row->setObjectName("marketField");
  auto *layout = new QHBoxLayout(row);
  layout->setContentsMargins(0, 0, 0, 0);
  layout->setSpacing(7);
  auto *text = new QLabel(label);
  text->setObjectName("secondaryText");
  layout->addWidget(text);
  layout->addWidget(field);
  return row;
}

QString orderDetails(const QJsonObject &order, bool includeBulk = true) {
  QStringList values;
  const QString subtype = order.value("subtype").toString();
  if (!subtype.isEmpty()) {
    values.append(subtype.left(1).toUpper() + subtype.mid(1));
  }
  for (const auto &[key, label] :
       {std::pair{"rank", "Rank %1"}, std::pair{"charges", "%1 charges"},
        std::pair{"amberStars", "%1 amber"},
        std::pair{"cyanStars", "%1 cyan"}}) {
    if (order.value(key).isDouble()) {
      values.append(QString::fromLatin1(label).arg(order.value(key).toInt()));
    }
  }
  const int perTrade = intValue(order, {"perTrade", "per_trade"}, 1);
  if (includeBulk && perTrade > 1) {
    values.append(QString("%1 per trade").arg(perTrade));
  }
  return values.join(" · ");
}
} // namespace

MarketItemDialog::MarketItemDialog(AppController *controller, QWidget *parent)
    : QDialog(parent), controller_(controller), image_(new QLabel),
      name_(new QLabel), status_(new QLabel), modes_(new QButtonGroup(this)),
      listings_(new QTableWidget), progress_(new QProgressBar),
      quantity_(new QSpinBox), price_(new QSpinBox), rank_(new QSpinBox),
      charges_(new QSpinBox), amberStars_(new QSpinBox),
      cyanStars_(new QSpinBox), perTrade_(new QSpinBox),
      subtype_(new QComboBox), rankRow_(nullptr), chargesRow_(nullptr),
      amberStarsRow_(nullptr), cyanStarsRow_(nullptr), perTradeRow_(nullptr),
      subtypeRow_(nullptr), variantTimer_(new QTimer(this)), copy_(new QPushButton),
      post_(new QPushButton), signIn_(new QPushButton) {
  setObjectName("marketDialog");
  setWindowTitle("Warframe.market");
  setModal(false);
  resize(760, 620);
  setMinimumSize(620, 500);

  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(18, 18, 18, 18);
  layout->setSpacing(12);

  auto *header = new QHBoxLayout;
  image_->setObjectName("marketItemImage");
  image_->setFixedSize(72, 72);
  image_->setAlignment(Qt::AlignCenter);
  header->addWidget(image_);
  name_->setObjectName("marketItemTitle");
  name_->setWordWrap(true);
  header->addWidget(name_, 1);
  auto *refresh = new QPushButton("Refresh");
  header->addWidget(refresh);
  layout->addLayout(header);

  auto *modeRow = new QHBoxLayout;
  modeRow->setSpacing(0);
  for (const auto &[label, side] :
       {std::pair{"WTS", "sell"}, std::pair{"WTB", "buy"}}) {
    auto *button = new QPushButton(label);
    button->setObjectName("marketSide");
    button->setCheckable(true);
    button->setProperty("side", side);
    modes_->addButton(button, QString::fromLatin1(side) == "sell" ? 0 : 1);
    modeRow->addWidget(button);
  }
  modeRow->addStretch();
  layout->addLayout(modeRow);

  progress_->setObjectName("priceProgress");
  progress_->setTextVisible(false);
  progress_->setRange(0, 1);
  progress_->setValue(0);
  layout->addWidget(progress_);

  listings_->setObjectName("marketListings");
  listings_->setColumnCount(5);
  listings_->setHorizontalHeaderLabels(
      {"Player", "Status", "Details", "Quantity", "Platinum"});
  listings_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
  listings_->horizontalHeader()->setSectionResizeMode(1,
                                                      QHeaderView::ResizeToContents);
  listings_->horizontalHeader()->setSectionResizeMode(2,
                                                      QHeaderView::ResizeToContents);
  listings_->horizontalHeader()->setSectionResizeMode(3,
                                                      QHeaderView::ResizeToContents);
  listings_->horizontalHeader()->setSectionResizeMode(4,
                                                      QHeaderView::ResizeToContents);
  listings_->verticalHeader()->hide();
  listings_->setSelectionBehavior(QAbstractItemView::SelectRows);
  listings_->setSelectionMode(QAbstractItemView::SingleSelection);
  listings_->setEditTriggers(QAbstractItemView::NoEditTriggers);
  listings_->setAlternatingRowColors(false);
  layout->addWidget(listings_, 1);

  auto *listingActions = new QHBoxLayout;
  copy_->setText("Copy whisper");
  copy_->setEnabled(false);
  listingActions->addWidget(copy_);
  status_->setObjectName("secondaryText");
  status_->setWordWrap(true);
  listingActions->addWidget(status_, 1);
  layout->addLayout(listingActions);

  auto *posting = new QWidget;
  posting->setObjectName("marketPosting");
  auto *postingLayout = new QGridLayout(posting);
  postingLayout->setContentsMargins(10, 9, 10, 9);
  postingLayout->setSpacing(10);
  quantity_->setRange(1, 9999);
  quantity_->setValue(1);
  price_->setRange(1, 900000);
  rank_->setRange(0, 100);
  charges_->setRange(0, 100000);
  amberStars_->setRange(0, 100);
  cyanStars_->setRange(0, 100);
  perTrade_->setRange(1, 6);
  perTrade_->setValue(1);
  rankRow_ = formRow("Rank", rank_);
  chargesRow_ = formRow("Charges", charges_);
  amberStarsRow_ = formRow("Amber", amberStars_);
  cyanStarsRow_ = formRow("Cyan", cyanStars_);
  perTradeRow_ = formRow("Per trade", perTrade_);
  subtypeRow_ = formRow("Type", subtype_);
  postingLayout->addWidget(formRow("Units", quantity_), 0, 0);
  postingLayout->addWidget(formRow("Price", price_), 0, 1);
  postingLayout->addWidget(rankRow_, 0, 2);
  postingLayout->addWidget(perTradeRow_, 0, 3);
  postingLayout->addWidget(subtypeRow_, 1, 0);
  postingLayout->addWidget(chargesRow_, 1, 1);
  postingLayout->addWidget(amberStarsRow_, 1, 2);
  postingLayout->addWidget(cyanStarsRow_, 1, 3);
  postingLayout->setColumnStretch(4, 1);
  post_->setObjectName("marketPrimary");
  postingLayout->addWidget(post_, 0, 5);
  signIn_->setText("Sign in");
  postingLayout->addWidget(signIn_, 0, 5);
  layout->addWidget(posting);

  connect(modes_, &QButtonGroup::idClicked, this,
          [this](int id) { setMode(id == 0 ? "sell" : "buy"); });
  connect(refresh, &QPushButton::clicked, this,
          [this] { requestData(true); });
  connect(listings_, &QTableWidget::itemSelectionChanged, this, [this] {
    copy_->setEnabled(listings_->currentRow() >= 0);
  });
  connect(listings_, &QTableWidget::cellDoubleClicked, this,
          [this](int, int) { copyWhisper(); });
  connect(copy_, &QPushButton::clicked, this,
          &MarketItemDialog::copyWhisper);
  connect(post_, &QPushButton::clicked, this,
          &MarketItemDialog::postOrder);
  connect(signIn_, &QPushButton::clicked, this, [this] {
    hide();
    emit signInRequested();
  });
  variantTimer_->setSingleShot(true);
  variantTimer_->setInterval(150);
  connect(variantTimer_, &QTimer::timeout, this,
          [this] { requestVariantData(); });
  auto variantChanged = [this] {
    variantQuote_ = {};
    variantQuoteFilters_ = {};
    initializePrice_ = true;
    variantTimer_->start();
    updateContent();
  };
  for (QSpinBox *field : {rank_, charges_, amberStars_, cyanStars_}) {
    connect(field, &QSpinBox::valueChanged, this, variantChanged);
  }
  connect(subtype_, &QComboBox::currentIndexChanged, this, variantChanged);
  connect(perTrade_, &QSpinBox::valueChanged, this, [this](int value) {
    quantity_->setSingleStep(value);
    const int normalized = qMax(value, quantity_->value() / value * value);
    quantity_->setValue(normalized);
  });
  connect(controller_, &AppController::marketCatalogChanged, this,
          &MarketItemDialog::updateContent);
  connect(controller_, &AppController::marketQuotesChanged, this,
          &MarketItemDialog::updateContent);
  connect(controller_, &AppController::marketVariantQuoteReady, this,
          [this](const QString &item, const QJsonObject &filters,
                 const QJsonObject &data) {
            if (item.compare(itemKey_, Qt::CaseInsensitive) != 0 ||
                filters != postingFilters()) {
              return;
            }
            variantQuote_ = data.value("quote").toObject();
            variantQuoteFilters_ = filters;
            updateContent();
          });
  connect(controller_, &AppController::marketVariantQuoteFailed, this,
          [this](const QString &item, const QJsonObject &filters,
                 const QString &error) {
            if (item.compare(itemKey_, Qt::CaseInsensitive) == 0 &&
                filters == postingFilters()) {
              status_->setText(error);
            }
          });
  connect(controller_, &AppController::marketAccountChanged, this, [this] {
    if (posting_ && !controller_->marketBusy()) {
      status_->setText(controller_->marketError().isEmpty()
                           ? "Order posted."
                           : controller_->marketError());
      posting_ = false;
    }
    updateContent();
  });
}

void MarketItemDialog::showItem(const QString &item, const QString &side) {
  if (item.isEmpty()) {
    return;
  }
  const bool changed = itemKey_.compare(item, Qt::CaseInsensitive) != 0;
  itemKey_ = item;
  if (changed) {
    initializePrice_ = true;
    quantity_->setValue(1);
    rank_->setValue(0);
    perTrade_->setValue(1);
    charges_->setValue(0);
    amberStars_->setValue(0);
    cyanStars_->setValue(0);
    variantQuote_ = {};
    variantQuoteFilters_ = {};
  }
  setMode(side == "buy" ? "buy" : "sell");
  updateContent();
  requestData(true);
  show();
  raise();
  activateWindow();
}

void MarketItemDialog::setMode(const QString &side) {
  const QString next = side == "buy" ? "buy" : "sell";
  if (mode_ != next) {
    mode_ = next;
    initializePrice_ = true;
  }
  modes_->button(mode_ == "sell" ? 0 : 1)->setChecked(true);
  updateContent();
}

void MarketItemDialog::updateContent() {
  if (itemKey_.isEmpty()) {
    return;
  }
  const QJsonObject item = controller_->marketItem(itemKey_);
  const QJsonObject row = controller_->marketQuote(itemKey_);
  updatePostingFields(item);
  const QJsonObject filters = postingFilters();
  const bool variant = !filters.isEmpty();
  const QJsonObject quote = variant
                                ? (variantQuoteFilters_ == filters
                                       ? variantQuote_
                                       : QJsonObject{})
                                : row.value("quote").toObject();
  const QString resolvedName = item.value("name").toString(itemKey_);
  name_->setText(resolvedName);
  setWindowTitle(resolvedName + " - Warframe.market");

  const QString assetId = item.value("asset").toObject().value("id").toString();
  const QString assetPath = controller_->assetPath(assetId);
  image_->setPixmap(assetPath.isEmpty()
                        ? QPixmap()
                        : QPixmap(assetPath).scaled(
                              image_->size(), Qt::KeepAspectRatio,
                              Qt::SmoothTransformation));
  image_->setText(assetPath.isEmpty() ? "..." : QString());

  const QJsonArray orders =
      quote.value(mode_ == "sell" ? "sell_orders" : "buy_orders").toArray();
  updateListings(orders);

  if (initializePrice_ && !quote.isEmpty() && (!variant || !variantQuote_.isEmpty())) {
    const QJsonValue suggested = quote.value(mode_ == "sell" ? "lowest_sell"
                                                              : "highest_buy");
    if (suggested.isDouble() && suggested.toInt() > 0) {
      price_->setValue(suggested.toInt());
    }
    initializePrice_ = false;
  }

  const bool loading = row.isEmpty() || (variant && variantQuote_.isEmpty());
  progress_->setRange(0, loading ? 0 : 1);
  if (!loading) {
    progress_->setValue(0);
  }
  const bool authenticated =
      controller_->marketAccount().value("authenticated").toBool();
  post_->setVisible(authenticated);
  signIn_->setVisible(!authenticated);
  post_->setText(mode_ == "sell" ? "Post sell" : "Post buy");
  post_->setEnabled(!controller_->marketBusy() && !item.isEmpty());
  if (!controller_->marketError().isEmpty() && !posting_) {
    status_->setText(controller_->marketError());
  } else if (loading) {
    status_->setText("Loading current listings...");
  } else if (orders.isEmpty()) {
    status_->setText("No online listings.");
  } else if (!posting_) {
    status_->clear();
  }
}

void MarketItemDialog::updateListings(const QJsonArray &orders) {
  listingRows_.clear();
  listings_->setRowCount(orders.size());
  int row = 0;
  for (const QJsonValue &value : orders) {
    const QJsonObject order = value.toObject();
    listingRows_.append(order);
    const QJsonObject user = order.value("user").toObject();
    const QString status = stringValue(user, {"status"});
    const int quantity = intValue(order, {"quantity"}, 1);
    const int perTrade = intValue(order, {"perTrade", "per_trade"}, 1);
    const int platinum = intValue(order, {"platinum"});
    const QString quantityText =
        perTrade > 1 ? QString("%1-pack / %2").arg(perTrade).arg(quantity)
                     : QString::number(quantity);
    const QStringList values = {listingPlayer(order), status, orderDetails(order), quantityText,
                                QString::number(platinum)};
    for (int column = 0; column < values.size(); ++column) {
      auto *cell = new QTableWidgetItem(values.at(column));
      if (column > 0) {
        cell->setTextAlignment(Qt::AlignCenter);
      }
      listings_->setItem(row, column, cell);
    }
    ++row;
  }
  listings_->setCurrentCell(-1, -1);
  copy_->setEnabled(false);
}

void MarketItemDialog::updatePostingFields(const QJsonObject &item) {
  const QJsonObject previous = postingFilters();
  const QSignalBlocker rankBlock(rank_);
  const QSignalBlocker chargesBlock(charges_);
  const QSignalBlocker amberBlock(amberStars_);
  const QSignalBlocker cyanBlock(cyanStars_);
  const QSignalBlocker subtypeBlock(subtype_);
  const int maxRank = item.value("max_rank").toInt();
  rank_->setMaximum(qMax(0, maxRank));
  rankRow_->setVisible(maxRank > 0);

  const int maxCharges = item.value("max_charges").toInt();
  charges_->setMaximum(qMax(0, maxCharges));
  chargesRow_->setVisible(maxCharges > 0);
  const int maxAmber = item.value("max_amber_stars").toInt();
  amberStars_->setMaximum(qMax(0, maxAmber));
  amberStarsRow_->setVisible(maxAmber > 0);
  const int maxCyan = item.value("max_cyan_stars").toInt();
  cyanStars_->setMaximum(qMax(0, maxCyan));
  cyanStarsRow_->setVisible(maxCyan > 0);

  const bool bulk = item.value("bulk_tradable").toBool();
  perTradeRow_->setVisible(bulk);

  const QJsonArray subtypes = item.value("subtypes").toArray();
  const QString selected = subtype_->currentData().toString();
  subtype_->clear();
  for (const QJsonValue &value : subtypes) {
    const QString subtype = value.toString();
    subtype_->addItem(subtype.left(1).toUpper() + subtype.mid(1), subtype);
  }
  const int selectedIndex = subtype_->findData(selected);
  subtype_->setCurrentIndex(selectedIndex >= 0 ? selectedIndex : 0);
  subtypeRow_->setVisible(!subtypes.isEmpty());
  const QJsonObject current = postingFilters();
  if (current != previous) {
    variantQuote_ = {};
    variantQuoteFilters_ = {};
    initializePrice_ = true;
    variantTimer_->start();
  }
}

void MarketItemDialog::requestData(bool refresh) {
  controller_->describeMarketItems({itemKey_});
  controller_->resolveMarketQuotes({itemKey_}, refresh);
  controller_->ensureMarket();
  progress_->setRange(0, 0);
  requestVariantData(refresh);
}

void MarketItemDialog::requestVariantData(bool refresh) {
  const QJsonObject filters = postingFilters();
  if (itemKey_.isEmpty() || filters.isEmpty()) {
    return;
  }
  controller_->requestMarketVariantQuote(itemKey_, filters, refresh);
  progress_->setRange(0, 0);
}

void MarketItemDialog::copyWhisper() {
  const int row = listings_->currentRow();
  if (row < 0 || row >= listingRows_.size()) {
    return;
  }
  const QJsonObject order = listingRows_.at(row);
  const QString player = listingPlayer(order);
  if (player.isEmpty()) {
    status_->setText("Listing has no player name.");
    return;
  }
  const QJsonObject item = controller_->marketItem(itemKey_);
  const QString name = item.value("name").toString(itemKey_);
  const int platinum = intValue(order, {"platinum"});
  const int perTrade = intValue(order, {"perTrade", "per_trade"}, 1);
  const QString amount = perTrade > 1 ? QString(" x%1").arg(perTrade) : QString();
  const QString action = mode_ == "sell" ? "buy" : "sell";
  const QString details = orderDetails(order, false);
  const QString listingName = details.isEmpty()
                                  ? name
                                  : QString("%1 (%2)").arg(name, details);
  const QString message =
      QString("/w %1 Hi! I want to %2:%3 \"%4\" for %5 platinum. "
              "(warframe.market through wfcli)")
          .arg(player, action, amount, listingName)
          .arg(platinum);
  QApplication::clipboard()->setText(message);
  status_->setText("Whisper copied.");
}

void MarketItemDialog::postOrder() {
  const QJsonObject item = controller_->marketItem(itemKey_);
  const QString id = item.value("id").toString();
  if (id.isEmpty()) {
    status_->setText("Market item metadata is still loading.");
    return;
  }
  QJsonObject order{{"itemId", id},
                    {"type", mode_},
                    {"platinum", price_->value()},
                    {"quantity", quantity_->value()},
                    {"visible", true}};
  if (rankRow_->isVisible()) {
    order.insert("rank", rank_->value());
  }
  if (chargesRow_->isVisible()) {
    order.insert("charges", charges_->value());
  }
  if (amberStarsRow_->isVisible()) {
    order.insert("amberStars", amberStars_->value());
  }
  if (cyanStarsRow_->isVisible()) {
    order.insert("cyanStars", cyanStars_->value());
  }
  if (perTradeRow_->isVisible()) {
    const int perTrade = perTrade_->value();
    const int normalized = qMax(perTrade, quantity_->value() / perTrade * perTrade);
    quantity_->setValue(normalized);
    order.insert("quantity", normalized);
    order.insert("perTrade", perTrade_->value());
  }
  if (subtypeRow_->isVisible() && subtype_->currentIndex() >= 0) {
    order.insert("subtype", subtype_->currentData().toString());
  }
  posting_ = true;
  status_->setText("Posting order...");
  controller_->marketCreateOrder(order);
  updateContent();
}

QJsonObject MarketItemDialog::postingFilters() const {
  QJsonObject filters;
  if (rankRow_ && rankRow_->isVisible()) {
    filters.insert("rank", rank_->value());
  }
  if (chargesRow_ && chargesRow_->isVisible()) {
    filters.insert("charges", charges_->value());
  }
  if (amberStarsRow_ && amberStarsRow_->isVisible()) {
    filters.insert("amberStars", amberStars_->value());
  }
  if (cyanStarsRow_ && cyanStarsRow_->isVisible()) {
    filters.insert("cyanStars", cyanStars_->value());
  }
  if (subtypeRow_ && subtypeRow_->isVisible() && subtype_->currentIndex() >= 0) {
    filters.insert("subtype", subtype_->currentData().toString());
  }
  return filters;
}

QString MarketItemDialog::listingPlayer(const QJsonObject &order) const {
  const QJsonObject user = order.value("user").toObject();
  return stringValue(user, {"ingameName", "ingame_name", "name"});
}
