# Bitcoin Dashboard

An Omarchy bar widget showing the live Bitcoin price with a 24h-trend color
cue, plus a popup dashboard panel with network stats, upcoming Bitcoin
holidays, halving countdown, and an optional encrypted "stack sats" position
tracker.

![Bitcoin Dashboard bar widget](./preview.png)

## Install

```bash
omarchy plugin add https://github.com/samb770/omarchy-bitcoin-dashboard.git --enable
```

## Uninstall

```bash
omarchy plugin remove sam.bitcoin
```

## Features

- Bar pill with current BTC price, colored by 24h trend
- Click opens the dashboard panel; middle-click forces an immediate refresh
- Network stats: block height, hashrate, difficulty adjustment, dominance
- Countdown to the next halving and upcoming Bitcoin holidays (Genesis Block
  Day, Pizza Day, Whitepaper Day, HODL Day)
- Optional encrypted position tracker ("stack sats") with a custody-risk
  assessment, stored password-protected inside `shell.json`

## Data sources

- [CoinGecko](https://www.coingecko.com/en/api) — price, market cap, dominance
- [mempool.space](https://mempool.space/docs/api) — block height, hashrate,
  difficulty adjustment

No API keys required; all requests are made directly from the client.

## License

[MIT](./LICENSE)
