(() => {
  "use strict";

  const products = [
    { id: "mascara", name: "Тушь для ресниц", detail: "Чёрная · 8 мл", price: 790 },
    { id: "balm", name: "Бальзам для губ", detail: "Без оттенка · 12 мл", price: 390 },
  ];
  const methods = [
    { id: "courier", name: "Курьер", time: "Суббота, 10:00–12:00", fee: 290 },
    { id: "pickup-point", name: "Пункт выдачи «Центральный»", time: "Суббота, 11:00–13:00", fee: 99 },
    { id: "store", name: "Самовывоз из магазина", time: "Воскресенье, 12:00–15:00", fee: 0 },
  ];
  const subtotal = products.reduce((sum, product) => sum + product.price, 0);
  const numbers = new Intl.NumberFormat("ru-RU");
  const app = document.querySelector("#app");

  const state = {
    variant: document.body.dataset.variant,
    step: "cart",
    selectedMethod: null,
  };

  function money(value) {
    return `${numbers.format(value)} ₽`;
  }

  function productList() {
    return `
      <ul class="products" aria-label="Товары в корзине">
        ${products.map((product) => `
          <li class="product-card">
            <div class="product-photo ${product.id}" aria-hidden="true"></div>
            <div class="product-info">
              <h2>${product.name}</h2>
              <p>${product.detail}</p>
            </div>
            <div class="product-amount"><strong>${money(product.price)}</strong><span>1 шт.</span></div>
          </li>`).join("")}
      </ul>`;
  }

  function fulfillment() {
    return `
      <fieldset class="fulfillment">
        <legend>Способ получения</legend>
        <p class="city">Москва</p>
        <div class="methods">
          ${methods.map((method) => `
            <label class="method">
              <input type="radio" name="fulfillment" value="${method.id}"
                ${state.selectedMethod === method.id ? "checked" : ""}>
              <span class="method-body">
                <span class="method-name">${method.name}</span>
                <span class="method-time">${method.time}</span>
              </span>
              <span class="method-amount">
                <span class="method-fee">${method.fee === 0 ? "Бесплатно" : money(method.fee)}</span>
                <span>Итого ${money(subtotal + method.fee)}</span>
              </span>
            </label>`).join("")}
        </div>
      </fieldset>`;
  }

  function summaryLines() {
    const selected = methods.find((method) => method.id === state.selectedMethod);
    const fee = selected && (selected.fee === 0 ? "Бесплатно" : money(selected.fee));
    const lastLabel = selected ? "Итого" : "Подытог";
    const value = subtotal + (selected?.fee ?? 0);
    return `
      <dl class="summary-lines">
        <div><dt>Товары, ${products.length} шт.</dt><dd>${money(subtotal)}</dd></div>
        <div><dt>Получение</dt><dd>${fee || (state.step === "cart" && state.variant === "A" ? "При оформлении" : "Выберите способ")}</dd></div>
      </dl>
      <div class="summary-total"><span>${lastLabel}</span><strong>${money(value)}</strong></div>`;
  }

  function summary(isCart) {
    return `
      <section class="summary" aria-labelledby="summary-title">
        <h2 id="summary-title">Ваш заказ</h2>
        <div id="summary-values" aria-live="polite" aria-atomic="true">${summaryLines()}</div>
        ${isCart ? `
          <button class="continue" type="button" data-go="checkout">К оформлению <span aria-hidden="true">→</span></button>
        ` : ""}
      </section>`;
  }

  function render({ focusHeading = false } = {}) {
    const isCart = state.step === "cart";
    const title = isCart ? "Корзина" : "Оформление";
    document.title = `${title} · Слой`;
    app.innerHTML = `
      <nav class="steps" aria-label="Шаги оформления">
        ${isCart
          ? '<span aria-current="step">Корзина</span>'
          : '<button class="step-button" type="button" data-go="cart">Корзина</button>'}
        <span class="step-divider" aria-hidden="true">/</span>
        <span ${isCart ? "" : 'aria-current="step"'}>Оформление</span>
      </nav>
      <h1 tabindex="-1">${title}</h1>
      <div class="layout">
        <div class="main-column">
          ${isCart ? productList() : ""}
          ${!isCart || state.variant === "B" ? fulfillment() : ""}
        </div>
        ${summary(isCart)}
      </div>`;

    if (focusHeading) {
      app.querySelector("h1").focus();
      window.scrollTo(0, 0);
    }
  }

  app.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-go]");
    if (!button) return;
    state.step = button.dataset.go;
    render({ focusHeading: true });
  });

  app.addEventListener("change", (event) => {
    if (event.target.name !== "fulfillment") return;
    state.selectedMethod = event.target.value;
    app.querySelector("#summary-values").innerHTML = summaryLines();
  });

  render();
})();
