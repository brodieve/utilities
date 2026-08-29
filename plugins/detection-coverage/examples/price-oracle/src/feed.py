"""Fixture: exchange price poller. Runs every 5 minutes."""

import logging

log = logging.getLogger(__name__)

EXCHANGES = ["bigvenue", "midvenue", "thinvenue"]


def fetch_price(exchange, pair):
    """Fetch a spot price. Fixture: no network call."""
    return {"exchange": exchange, "pair": pair, "price": 68000.0}


def poll(pair):
    prices = []
    for exchange in EXCHANGES:
        quote = fetch_price(exchange, pair)
        log.info(
            "price_polled",
            extra={
                "event": "price_polled",
                "pair": pair,
                "exchange": exchange,
                "price": quote["price"],
                "ts": "2026-08-29T14:00:00Z",
            },
        )
        prices.append(quote["price"])

    # Published without any cross-venue plausibility check.
    published = prices[0]

    log.info("poll_complete", extra={"event": "poll_complete", "status": "ok", "pair": pair})
    return published
