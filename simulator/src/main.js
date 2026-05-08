import "./styles.css";

const COLORS = ["#0c5b7d", "#c05a2b", "#2f7d50", "#7b4cb4", "#9d6b08", "#4a6678"];

const PRESETS = [
  { id: "q4", label: "x^(1/4)", exponent: 0.25 },
  { id: "q3", label: "x^(1/3)", exponent: 1 / 3 },
  { id: "sqrt", label: "x^(1/2)", exponent: 0.5 },
  { id: "twothirds", label: "x^(2/3)", exponent: 2 / 3 },
  { id: "linear", label: "x", exponent: 1 },
];

const ASSET_PRESETS = [
  { id: "usdc", label: "USDC", symbol: "USDC", decimals: 6, price: 1 },
  { id: "wbtc", label: "WBTC", symbol: "WBTC", decimals: 8, price: 100_000 },
  { id: "value12", label: "12 Decimal Asset", symbol: "VAL12", decimals: 12, price: 1 },
  { id: "weth", label: "WETH", symbol: "WETH", decimals: 18, price: 3_500 },
  { id: "custom", label: "Custom", symbol: "ASSET", decimals: 18, price: 1 },
];

const state = {
  initialSupply: 3_000_000,
  initialBacking: 0,
  minBootstrapNav: 0,
  maxSupply: 100_000_000,
  protocolFeeBps: 250,
  reserveAsset: "usdc",
  reserveAssetDecimals: 6,
  reserveAssetPrice: 1,
  customExponent: 0.5,
  selectedCurves: new Set(["q4", "q3", "sqrt", "twothirds"]),
  activeCurve: "sqrt",
  dailyMode: "pool",
  dailyBuyVolume: 1_000_000,
  dailySellVolume: 1_000_000,
  sellRedemptionShare: 0,
  volumeVolatility: 70,
  days: 365,
};

const app = document.querySelector("#app");
const tooltip = document.createElement("div");
tooltip.className = "tooltip";
document.body.appendChild(tooltip);

app.innerHTML = `
  <div class="app">
    <aside class="sidebar">
      <div class="brand">
        <h1>Enten Curve Lab</h1>
        <span class="status-pill">Bancor</span>
      </div>

      <section class="control-group">
        <h2>Launch State</h2>
        ${numberField("initialSupply", "Initial Supply", state.initialSupply, 0, 1)}
        ${numberField("initialBacking", "Initial Backing", state.initialBacking, 0, 1)}
        ${numberField("minBootstrapNav", "NAV Floor", state.minBootstrapNav, 0, 0.0001)}
        ${numberField("maxSupply", "Graph Max Supply", state.maxSupply, 1, 1)}
      </section>

      <section class="control-group">
        <h2>Reserve Asset</h2>
        <div class="field">
          <label for="reserveAsset">Asset</label>
          <select id="reserveAsset" data-bind="reserveAsset">
            ${ASSET_PRESETS.map((asset) => `<option value="${asset.id}">${asset.label}</option>`).join("")}
          </select>
        </div>
        ${numberField("reserveAssetDecimals", "Decimals", state.reserveAssetDecimals, 0, 1)}
        ${numberField("reserveAssetPrice", "Asset Price", state.reserveAssetPrice, 0, 0.0001)}
      </section>

      <section class="control-group">
        <h2>Curve</h2>
        <div class="field">
          <label for="activeCurve">Active Curve</label>
          <select id="activeCurve" data-bind="activeCurve">
            ${PRESETS.map((preset) => `<option value="${preset.id}">${preset.label}</option>`).join("")}
            <option value="custom">Custom</option>
          </select>
        </div>
        ${numberField("customExponent", "Custom Exponent", state.customExponent, 0.01, 0.01)}
        ${numberField("protocolFeeBps", "Protocol Fee BPS", state.protocolFeeBps, 0, 1)}
        <div class="field">
          <label>Compare</label>
          <div class="curve-grid">
            ${PRESETS.map((preset) => `<button class="curve-chip active" data-curve="${preset.id}">${preset.label}</button>`).join("")}
          </div>
        </div>
      </section>

      <section class="control-group">
        <h2>Annual Flow</h2>
        <div class="segmented" role="tablist">
          <button class="active" data-mode="pool">Pool Sells</button>
          <button data-mode="mixed">Mixed Sells</button>
        </div>
        ${numberField("dailyBuyVolume", "Buy Value / Day", state.dailyBuyVolume, 0, 1)}
        ${numberField("dailySellVolume", "Sell Value / Day", state.dailySellVolume, 0, 1)}
        ${numberField("sellRedemptionShare", "Redeem Share %", state.sellRedemptionShare, 0, 1)}
        ${numberField("volumeVolatility", "Volume Volatility %", state.volumeVolatility, 0, 1)}
        ${numberField("days", "Days", state.days, 1, 1)}
      </section>
    </aside>

    <section class="main">
      <header class="topbar">
        <div class="title-block">
          <h2>Bancor Buy-Only Issuance</h2>
          <p id="formulaLine"></p>
        </div>
      </header>

      <section class="metrics">
        ${metric("Launch NAV", "launchNav")}
        ${metric("Launch Spot", "launchSpot")}
        ${metric("Reserve Ratio", "reserveRatio")}
        ${metric("Fee Gross-Up", "feeGrossUp")}
        ${metric("Launch Asset Units", "launchAssetUnits")}
        ${metric("Raw Backing Units", "launchRawUnits")}
      </section>

      <section class="workspace">
        <div class="chart-grid">
          ${chartPanel("priceChart", "Spot Mint Price", "supply")}
          ${chartPanel("navChart", "NAV", "supply")}
          ${chartPanel("overlayChart", "NAV vs Spot Mint Price", "supply")}
          ${chartPanel("backingChart", "Backing Collected", "supply")}
          ${chartPanel("annualChart", "Annual Path", "days")}
        </div>
        <section class="table-panel">
          <div class="table-head">
            <h3>Checkpoints</h3>
            <span id="checkpointSubtitle"></span>
          </div>
          <div style="overflow:auto">
            <table>
              <thead>
                <tr>
                  <th>Curve</th>
                  <th>RR</th>
                  <th>Spot / NAV</th>
                  <th>25% Supply</th>
                  <th>50% Supply</th>
                  <th>75% Supply</th>
                  <th>100% Supply</th>
                </tr>
              </thead>
              <tbody id="checkpointRows"></tbody>
            </table>
          </div>
        </section>
      </section>
    </section>
  </div>
`;

const charts = {
  priceChart: document.querySelector("#priceChart"),
  navChart: document.querySelector("#navChart"),
  overlayChart: document.querySelector("#overlayChart"),
  backingChart: document.querySelector("#backingChart"),
  annualChart: document.querySelector("#annualChart"),
};

bindInputs();
render();

window.addEventListener("resize", render);

function numberField(id, label, value, min, step) {
  return `
    <div class="field">
      <label for="${id}">${label}</label>
      <input id="${id}" data-bind="${id}" type="number" min="${min}" step="${step}" value="${value}" />
    </div>
  `;
}

function metric(label, id) {
  return `
    <div class="metric">
      <span>${label}</span>
      <strong id="${id}"></strong>
    </div>
  `;
}

function chartPanel(id, title, axis) {
  return `
    <section class="chart-panel">
      <div class="chart-head">
        <h3>${title}</h3>
        <span>${axis}</span>
      </div>
      <div class="chart-wrap"><canvas id="${id}"></canvas></div>
    </section>
  `;
}

function bindInputs() {
  document.querySelectorAll("[data-bind]").forEach((input) => {
    input.addEventListener("input", () => {
      const key = input.dataset.bind;
      if (key === "reserveAsset") {
        state.reserveAsset = input.value;
        const asset = getActiveAsset();
        state.reserveAssetDecimals = asset.decimals;
        state.reserveAssetPrice = asset.price;
      } else if (input.tagName === "SELECT") {
        state[key] = input.value;
      } else {
        state[key] = Number(input.value);
      }
      render();
    });
  });

  document.querySelectorAll("[data-mode]").forEach((button) => {
    button.addEventListener("click", () => {
      state.dailyMode = button.dataset.mode;
      if (state.dailyMode === "pool") state.sellRedemptionShare = 0;
      if (state.dailyMode === "mixed" && state.sellRedemptionShare === 0) state.sellRedemptionShare = 50;
      document.querySelector("#sellRedemptionShare").value = state.sellRedemptionShare;
      render();
    });
  });

  document.querySelectorAll("[data-curve]").forEach((button) => {
    button.addEventListener("click", () => {
      const id = button.dataset.curve;
      if (state.selectedCurves.has(id)) {
        state.selectedCurves.delete(id);
      } else {
        state.selectedCurves.add(id);
      }
      if (state.selectedCurves.size === 0) state.selectedCurves.add(id);
      render();
    });
  });
}

function render() {
  syncControls();

  const active = getActiveCurve();
  const asset = getActiveAsset();
  const launchNav = nav(state.initialBacking, state.initialSupply);
  const effectiveLaunchNav = Math.max(launchNav, state.minBootstrapNav);
  const reserveRatio = reserveRatioForExponent(active.exponent);
  const launchSpot = effectiveLaunchNav / reserveRatio;
  const feeGrossUp = 10000 / Math.max(1, 10000 - state.protocolFeeBps);
  const assetDecimals = normalizedDecimals(state.reserveAssetDecimals);
  const assetPrice = Math.max(0, state.reserveAssetPrice);
  const launchAssetUnits = assetPrice > 0 ? state.initialBacking / assetPrice : 0;
  const launchRawUnits = launchAssetUnits * 10 ** assetDecimals;

  document.querySelector("#formulaLine").textContent =
    `price = NAV / RR, ${active.label}, exponent ${formatCompact(active.exponent)}, reserve ${asset.symbol}`;
  document.querySelector("#launchNav").textContent = money(launchNav);
  document.querySelector("#launchSpot").textContent = money(launchSpot);
  document.querySelector("#reserveRatio").textContent = percent(reserveRatio);
  document.querySelector("#feeGrossUp").textContent = `${feeGrossUp.toFixed(4)}x`;
  document.querySelector("#launchAssetUnits").textContent =
    `${formatAssetAmount(launchAssetUnits)} ${asset.symbol}`;
  document.querySelector("#launchRawUnits").textContent = formatBaseUnits(launchRawUnits);

  const series = selectedCurves().map((curve, index) => ({
    ...curve,
    color: COLORS[index % COLORS.length],
    points: deterministicPoints(curve.exponent),
  }));

  drawChart(charts.priceChart, series, "price", money, "Supply", "Spot");
  drawChart(charts.navChart, series, "nav", money, "Supply", "NAV");
  drawChart(
    charts.overlayChart,
    overlaySeries(active.exponent),
    "value",
    money,
    "Supply",
    "Price"
  );
  drawChart(charts.backingChart, series, "backing", compactMoney, "Supply", "Backing");

  const annual = annualPath(active.exponent);
  drawChart(
    charts.annualChart,
    [
      { label: "NAV", color: "#0c5b7d", points: annual.map((p) => ({ x: p.day, nav: p.nav })) },
      { label: "Utilization", color: "#c05a2b", points: annual.map((p) => ({ x: p.day, nav: p.utilization })) },
    ],
    "nav",
    (v) => (v < 1.6 ? v.toFixed(3) : money(v)),
    "Day",
    "Value"
  );

  renderTable(series);
}

function overlaySeries(exponent) {
  const points = deterministicPoints(exponent);
  return [
    {
      label: "NAV",
      color: "#0c5b7d",
      points: points.map((point) => ({ x: point.x, value: point.nav })),
    },
    {
      label: "Spot mint",
      color: "#c05a2b",
      points: points.map((point) => ({ x: point.x, value: point.price })),
    },
  ];
}

function syncControls() {
  document.querySelector("#activeCurve").value = state.activeCurve;
  document.querySelector("#reserveAsset").value = state.reserveAsset;
  document.querySelector("#reserveAssetDecimals").value = normalizedDecimals(state.reserveAssetDecimals);
  document.querySelector("#reserveAssetPrice").value = state.reserveAssetPrice;
  document.querySelectorAll("[data-mode]").forEach((button) => {
    button.classList.toggle("active", button.dataset.mode === state.dailyMode);
  });
  document.querySelectorAll("[data-curve]").forEach((button) => {
    button.classList.toggle("active", state.selectedCurves.has(button.dataset.curve));
  });
}

function selectedCurves() {
  const curves = PRESETS.filter((preset) => state.selectedCurves.has(preset.id));
  if (state.activeCurve === "custom") {
    curves.push({ id: "custom", label: `x^(${formatCompact(state.customExponent)})`, exponent: state.customExponent });
  }
  return curves;
}

function getActiveCurve() {
  if (state.activeCurve === "custom") {
    return { id: "custom", label: `x^(${formatCompact(state.customExponent)})`, exponent: state.customExponent };
  }
  return PRESETS.find((preset) => preset.id === state.activeCurve) || PRESETS[2];
}

function getActiveAsset() {
  return ASSET_PRESETS.find((asset) => asset.id === state.reserveAsset) || ASSET_PRESETS[0];
}

function deterministicPoints(exponent) {
  const points = [];
  const startSupply = Math.max(1, state.initialSupply);
  const startBacking = state.initialBacking;
  const steps = 160;

  for (let i = 0; i <= steps; i += 1) {
    const t = i / steps;
    const supply = startSupply + Math.max(0, state.maxSupply - startSupply) * t;
    const backing = projectedBacking(startSupply, startBacking, supply, exponent);
    const currentNav = nav(backing, supply);
    const rr = reserveRatioForExponent(exponent);
    points.push({
      x: supply,
      price: currentNav / rr,
      nav: currentNav,
      backing,
    });
  }

  return points;
}

function projectedBacking(startSupply, startBacking, supply, exponent) {
  if (supply <= 0) return 0;
  if (startBacking > 0) {
    return startBacking * (supply / startSupply) ** (exponent + 1);
  }
  const floorBacking = state.minBootstrapNav * startSupply;
  if (floorBacking > 0) {
    return floorBacking * (supply / startSupply) ** (exponent + 1) - floorBacking;
  }
  return 0;
}

function annualPath(exponent) {
  const points = [];
  let supply = Math.max(1, state.initialSupply);
  let backing = state.initialBacking;
  let seed = 1337;
  const redeemShare = clamp(state.sellRedemptionShare / 100, 0, 1);

  for (let day = 0; day <= state.days; day += 1) {
    points.push({
      day,
      nav: nav(backing, supply),
      utilization: supply / state.maxSupply,
    });
    if (day === state.days) break;

    const buyVolume = state.dailyBuyVolume * volumeMultiplier(day, seed, state.volumeVolatility);
    const sellVolume = state.dailySellVolume * volumeMultiplier(day, seed + 991, state.volumeVolatility);
    const costNav = Math.max(nav(backing, supply), state.minBootstrapNav);
    const rr = reserveRatioForExponent(exponent);
    const estimatedPrice = costNav / rr;
    const mintAmount = estimatedPrice > 0 ? buyVolume / estimatedPrice : 0;

    if (mintAmount > 0 && supply < state.maxSupply) {
      const cappedMint = Math.min(mintAmount, state.maxSupply - supply);
      const reserveIn = quoteReserveIn(supply, backing, cappedMint, exponent);
      backing += reserveIn;
      supply += cappedMint;
    }

    const redemptionDollars = sellVolume * redeemShare;
    const currentNav = nav(backing, supply);
    if (currentNav > 0 && redemptionDollars > 0) {
      const tokensRedeemed = Math.min(redemptionDollars / currentNav, supply * 0.999999);
      const backingOut = tokensRedeemed * currentNav;
      supply -= tokensRedeemed;
      backing -= backingOut;
    }
  }

  return points;
}

function quoteReserveIn(supply, backing, tokenAmount, exponent) {
  if (tokenAmount <= 0) return 0;
  const baseBacking = backing > 0 ? backing : state.minBootstrapNav * supply;
  if (baseBacking <= 0) return 0;
  const supplyAfter = supply + tokenAmount;
  const growth = (supplyAfter / supply) ** (exponent + 1);
  return baseBacking * (growth - 1);
}

function volumeMultiplier(day, seed, volatilityPercent) {
  const sigma = Math.max(0, volatilityPercent) / 100;
  const u1 = seeded(day * 17 + seed);
  const u2 = seeded(day * 31 + seed * 3);
  const z = Math.sqrt(-2 * Math.log(Math.max(0.000001, u1))) * Math.cos(2 * Math.PI * u2);
  let value = Math.exp(-0.5 * sigma * sigma + sigma * z);
  const event = seeded(day * 53 + seed * 7);
  if (event < 0.03) value *= 3 + 5 * seeded(day * 67 + seed);
  if (event > 0.95) value *= 0.05 + 0.2 * seeded(day * 71 + seed);
  return value;
}

function seeded(n) {
  const x = Math.sin(n * 12.9898) * 43758.5453;
  return x - Math.floor(x);
}

function drawChart(canvas, series, key, valueFormatter, xLabel, yLabel) {
  const rect = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.floor(rect.width * dpr));
  canvas.height = Math.max(1, Math.floor(rect.height * dpr));
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, rect.width, rect.height);

  const all = series.flatMap((item) => item.points);
  const xs = all.map((p) => p.x);
  const ys = all.map((p) => p[key]).filter((v) => Number.isFinite(v));
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(0, Math.min(...ys));
  const maxY = Math.max(0.000001, Math.max(...ys));
  const yPad = maxY === minY ? 1 : (maxY - minY) * 0.08;
  const yMax = maxY + yPad;
  const yTicks = 4;
  const yLabels = Array.from({ length: yTicks + 1 }, (_, i) => {
    const value = minY + ((yMax - minY) * (yTicks - i)) / yTicks;
    return valueFormatter(value);
  });

  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, rect.width, rect.height);
  ctx.font = "12px Inter, system-ui, sans-serif";

  const widestYLabel = yLabels.reduce((width, label) => Math.max(width, ctx.measureText(label).width), 0);
  const leftGutter = Math.ceil(Math.min(116, Math.max(68, widestYLabel + 22)));
  const padding = {
    left: leftGutter,
    right: 22,
    top: 24,
    bottom: 48,
  };
  const plot = {
    x: padding.left,
    y: padding.top,
    w: Math.max(80, rect.width - padding.left - padding.right),
    h: Math.max(100, rect.height - padding.top - padding.bottom),
  };

  const scaleX = (x) => plot.x + ((x - minX) / Math.max(1e-9, maxX - minX)) * plot.w;
  const scaleY = (y) => plot.y + plot.h - ((y - minY) / Math.max(1e-9, yMax - minY)) * plot.h;

  ctx.fillStyle = "#fbfcfd";
  ctx.fillRect(plot.x, plot.y, plot.w, plot.h);
  ctx.strokeStyle = "#e7ecf1";
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let i = 0; i <= yTicks; i += 1) {
    const y = plot.y + (plot.h * i) / yTicks;
    ctx.moveTo(plot.x, y);
    ctx.lineTo(plot.x + plot.w, y);
  }
  ctx.stroke();

  ctx.strokeStyle = "#cfd8e1";
  ctx.strokeRect(plot.x, plot.y, plot.w, plot.h);

  ctx.fillStyle = "#6a7885";
  ctx.textAlign = "right";
  ctx.textBaseline = "middle";
  for (let i = 0; i <= yTicks; i += 1) {
    const y = plot.y + (plot.h * i) / yTicks;
    ctx.fillText(yLabels[i], plot.x - 10, y);
  }

  ctx.textAlign = "center";
  ctx.textBaseline = "top";
  ctx.fillText(formatAxis(minX), plot.x, plot.y + plot.h + 10);
  ctx.fillText(formatAxis(maxX), plot.x + plot.w, plot.y + plot.h + 10);

  ctx.save();
  ctx.beginPath();
  ctx.rect(plot.x, plot.y, plot.w, plot.h);
  ctx.clip();

  series.forEach((item) => {
    ctx.strokeStyle = item.color;
    ctx.lineWidth = 2;
    ctx.beginPath();
    item.points.forEach((point, index) => {
      const x = scaleX(point.x);
      const y = scaleY(point[key]);
      if (index === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.stroke();
  });
  ctx.restore();

  ctx.fillStyle = "#394856";
  ctx.textAlign = "left";
  ctx.textBaseline = "top";
  ctx.fillText(yLabel, plot.x, 4);
  ctx.textAlign = "right";
  ctx.fillText(xLabel, plot.x + plot.w, rect.height - 18);

  canvas.onmousemove = (event) => {
    const xRatio = clamp((event.offsetX - plot.x) / plot.w, 0, 1);
    const xValue = minX + (maxX - minX) * xRatio;
    const rows = series.map((item) => {
      const point = nearestPoint(item.points, xValue);
      return `<div><span style="color:${item.color}">■</span> ${item.label}: ${valueFormatter(point[key])}</div>`;
    });
    tooltip.innerHTML = `<strong>${formatAxis(xValue)}</strong>${rows.join("")}`;
    tooltip.style.left = `${event.clientX}px`;
    tooltip.style.top = `${event.clientY}px`;
    tooltip.style.display = "block";
  };
  canvas.onmouseleave = () => {
    tooltip.style.display = "none";
  };
}

function nearestPoint(points, x) {
  let best = points[0];
  let bestDistance = Math.abs(best.x - x);
  for (const point of points) {
    const distance = Math.abs(point.x - x);
    if (distance < bestDistance) {
      best = point;
      bestDistance = distance;
    }
  }
  return best;
}

function renderTable(series) {
  document.querySelector("#checkpointSubtitle").textContent = `max supply ${formatAxis(state.maxSupply)}`;
  const checkpoints = [0.25, 0.5, 0.75, 1];
  document.querySelector("#checkpointRows").innerHTML = series
    .map((item, index) => {
      const cells = checkpoints
        .map((fraction) => {
          const supply = Math.max(state.initialSupply, state.maxSupply * fraction);
          const backing = projectedBacking(Math.max(1, state.initialSupply), state.initialBacking, supply, item.exponent);
          const currentNav = nav(backing, supply);
          const price = currentNav / reserveRatioForExponent(item.exponent);
          return `<td>${money(price)} / ${compactMoney(backing)}</td>`;
        })
        .join("");
      return `
        <tr>
          <td><span class="swatch" style="background:${COLORS[index % COLORS.length]}"></span>${item.label}</td>
          <td>${percent(reserveRatioForExponent(item.exponent))}</td>
          <td>${(1 / reserveRatioForExponent(item.exponent)).toFixed(2)}x</td>
          ${cells}
        </tr>
      `;
    })
    .join("");
}

function reserveRatioForExponent(exponent) {
  return 1 / (exponent + 1);
}

function nav(backing, supply) {
  if (supply <= 0) return 0;
  return Math.max(0, backing) / supply;
}

function money(value) {
  if (!Number.isFinite(value)) return "$0.00";
  if (Math.abs(value) < 0.0001 && value !== 0) return `$${value.toExponential(2)}`;
  return `$${value.toLocaleString(undefined, { maximumFractionDigits: value < 10 ? 4 : 2 })}`;
}

function compactMoney(value) {
  if (!Number.isFinite(value)) return "$0";
  return `$${formatAxis(value)}`;
}

function formatAxis(value) {
  if (!Number.isFinite(value)) return "0";
  const abs = Math.abs(value);
  if (abs >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)}B`;
  if (abs >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`;
  if (abs >= 1_000) return `${(value / 1_000).toFixed(2)}K`;
  return value.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

function percent(value) {
  return `${(value * 100).toFixed(2)}%`;
}

function formatCompact(value) {
  return Number(value).toFixed(4).replace(/0+$/, "").replace(/\.$/, "");
}

function formatAssetAmount(value) {
  if (!Number.isFinite(value)) return "0";
  if (Math.abs(value) < 0.000001 && value !== 0) return value.toExponential(2);
  return value.toLocaleString(undefined, { maximumFractionDigits: value < 1 ? 8 : 4 });
}

function formatBaseUnits(value) {
  if (!Number.isFinite(value)) return "0";
  if (value === 0) return "0";
  if (Math.abs(value) >= 1e21) return value.toExponential(4);
  return Math.round(value).toLocaleString();
}

function normalizedDecimals(value) {
  return Math.trunc(clamp(Number(value) || 0, 0, 18));
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
