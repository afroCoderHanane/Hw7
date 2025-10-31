

"""
AWS Lambda: Cost Calculator for Flash Sale System

Expected event payload (direct invoke or API Gateway proxy):
{
  "currency": "USD",                 # optional; default: USD
  "items": [
    {"sku": "LAP-001", "unit_price": 999.99, "quantity": 1},
    {"sku": "MOU-001", "unit_price": 29.99,  "quantity": 2}
  ],
  "discounts": [                      # optional; supports multiple discounts
    {"type": "PERCENT", "value": 10},       # 10% off subtotal
    {"type": "AMOUNT",  "value": 5.00}      # $5 off
  ],
  "shipping": {                        # optional
    "mode": "FLAT" | "PER_ITEM",          # default: FLAT
    "rate": 9.99,                        # flat rate or per-item rate
    "free_over": 100.0,                  # optional: free shipping threshold (pre-tax, post-discount)
  },
  "tax": {
    "rate_percent": 8.875,               # tax rate in percent; e.g., 8.875 for NYC
    "apply_on_shipping": false           # default: false
  }
}

Response body:
{
  "currency": "USD",
  "subtotal": "1059.97",
  "discount": "110.00",
  "shipping": "0.00",
  "tax": "84.07",
  "total": "1034.04",
  "line_items": [
    {"sku": "LAP-001", "quantity": 1, "unit_price": "999.99", "line_subtotal": "999.99"},
    {"sku": "MOU-001", "quantity": 2, "unit_price": "29.99",  "line_subtotal": "59.98"}
  ]
}

Notes:
- Uses Decimal to avoid floating point issues.
- Strict validation with clear error messages.
- Works with API Gateway proxy (stringified body) or direct Lambda invoke (dict body).
"""
from __future__ import annotations

import json
import math
from decimal import Decimal, ROUND_HALF_UP, getcontext
from typing import Any, Dict, List, Tuple

# Configure money math: 2 decimal places, bankers rounding avoided (use HALF_UP)
getcontext().prec = 28

TWO_PLACES = Decimal("0.01")


class BadRequest(ValueError):
    pass


def d(val: Any) -> Decimal:
    """Coerce val into Decimal safely."""
    if isinstance(val, Decimal):
        return val
    try:
        # Convert bool -> int -> str to avoid True==1 corner cases in Decimal
        if isinstance(val, bool):
            val = int(val)
        return Decimal(str(val))
    except Exception as e:
        raise BadRequest(f"Invalid numeric value: {val!r}") from e


def q(val: Decimal) -> Decimal:
    """Quantize to 2 dp using HALF_UP."""
    return val.quantize(TWO_PLACES, rounding=ROUND_HALF_UP)


def parse_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """Extract body from direct or API Gateway proxy event."""
    if not isinstance(event, dict):
        raise BadRequest("Event must be a JSON object")

    body = event
    # API Gateway HTTP API / REST API often wraps under "body"
    if "body" in event:
        raw = event["body"]
        if raw is None:
            body = {}
        elif isinstance(raw, (bytes, bytearray)):
            body = json.loads(raw.decode("utf-8"))
        elif isinstance(raw, str):
            body = json.loads(raw)
        elif isinstance(raw, dict):
            body = raw
        else:
            raise BadRequest("Unsupported body type")

    if not isinstance(body, dict):
        raise BadRequest("Request body must be a JSON object")

    return body


def validate_items(items: Any) -> List[Dict[str, Any]]:
    if not isinstance(items, list) or not items:
        raise BadRequest("'items' must be a non-empty list")

    cleaned: List[Dict[str, Any]] = []
    for idx, it in enumerate(items):
        if not isinstance(it, dict):
            raise BadRequest(f"Item at index {idx} must be an object")
        sku = it.get("sku")
        if not isinstance(sku, str) or not sku.strip():
            raise BadRequest(f"Item at index {idx} missing valid 'sku'")
        qty = it.get("quantity")
        price = it.get("unit_price")
        try:
            qty_i = int(qty)
        except Exception:
            raise BadRequest(f"Item '{sku}': 'quantity' must be an integer")
        if qty_i < 0:
            raise BadRequest(f"Item '{sku}': 'quantity' must be >= 0")
        price_d = d(price)
        if price_d < 0:
            raise BadRequest(f"Item '{sku}': 'unit_price' must be >= 0")
        cleaned.append({
            "sku": sku.strip(),
            "quantity": qty_i,
            "unit_price": q(price_d),
        })
    return cleaned


def compute_subtotal(items: List[Dict[str, Any]]) -> Tuple[Decimal, List[Dict[str, Any]]]:
    lines: List[Dict[str, Any]] = []
    subtotal = Decimal("0")
    for it in items:
        line = q(d(it["unit_price"]) * d(it["quantity"]))
        subtotal += line
        lines.append({
            "sku": it["sku"],
            "quantity": it["quantity"],
            "unit_price": f"{q(d(it['unit_price']))}",
            "line_subtotal": f"{line}",
        })
    return q(subtotal), lines


def compute_discounts(subtotal: Decimal, discounts: Any) -> Decimal:
    if not discounts:
        return Decimal("0")
    total_disc = Decimal("0")
    if not isinstance(discounts, list):
        raise BadRequest("'discounts' must be a list")
    for idx, disc in enumerate(discounts):
        if not isinstance(disc, dict):
            raise BadRequest(f"Discount at index {idx} must be an object")
        typ = str(disc.get("type", "")).upper()
        value = disc.get("value")
        if typ not in {"PERCENT", "AMOUNT"}:
            raise BadRequest(f"Unsupported discount type: {typ!r}")
        if value is None:
            raise BadRequest("Discount missing 'value'")
        if typ == "PERCENT":
            pct = d(value)
            if pct < 0:
                raise BadRequest("Percent discount must be >= 0")
            amt = q(subtotal * (pct / Decimal("100")))
        else:  # AMOUNT
            amt = q(d(value))
            if amt < 0:
                raise BadRequest("Amount discount must be >= 0")
        total_disc += amt
    # Cap discounts at subtotal
    return q(min(total_disc, subtotal))


def compute_shipping(items: List[Dict[str, Any]], discounted_subtotal: Decimal, shipping: Any) -> Decimal:
    if not shipping:
        return Decimal("0")
    if not isinstance(shipping, dict):
        raise BadRequest("'shipping' must be an object")
    mode = str(shipping.get("mode", "FLAT")).upper()
    rate = q(d(shipping.get("rate", 0)))
    if rate < 0:
        raise BadRequest("Shipping 'rate' must be >= 0")
    free_over = shipping.get("free_over")
    free_over_d = q(d(free_over)) if free_over is not None else None

    if free_over_d is not None and discounted_subtotal >= free_over_d:
        return Decimal("0")

    if mode == "PER_ITEM":
        total_qty = sum(int(it["quantity"]) for it in items)
        return q(rate * d(total_qty))
    elif mode == "FLAT":
        return rate
    else:
        raise BadRequest("Shipping 'mode' must be 'FLAT' or 'PER_ITEM'")


def compute_tax(tax_cfg: Any, taxable_base: Decimal, shipping: Decimal) -> Decimal:
    if not tax_cfg:
        return Decimal("0")
    if not isinstance(tax_cfg, dict):
        raise BadRequest("'tax' must be an object")
    rate_percent = d(tax_cfg.get("rate_percent", 0))
    if rate_percent < 0:
        raise BadRequest("Tax 'rate_percent' must be >= 0")
    apply_on_shipping = bool(tax_cfg.get("apply_on_shipping", False))

    base = taxable_base + (shipping if apply_on_shipping else Decimal("0"))
    tax = q(base * (rate_percent / Decimal("100")))
    return tax


def build_response(status_code: int, payload: Dict[str, Any]) -> Dict[str, Any]:
    """Format like API Gateway proxy integration."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    try:
        body = parse_event(event)
        currency = str(body.get("currency", "USD")).upper()
        items = validate_items(body.get("items"))

        subtotal, line_items = compute_subtotal(items)
        discount = compute_discounts(subtotal, body.get("discounts"))

        discounted_subtotal = q(subtotal - discount)
        shipping = compute_shipping(items, discounted_subtotal, body.get("shipping"))

        # By default, tax applies on (subtotal - discount); shipping optional via flag
        tax = compute_tax(body.get("tax"), discounted_subtotal, shipping)

        total = q(discounted_subtotal + shipping + tax)

        response = {
            "currency": currency,
            "subtotal": f"{subtotal}",
            "discount": f"{discount}",
            "shipping": f"{shipping}",
            "tax": f"{tax}",
            "total": f"{total}",
            "line_items": line_items,
        }
        return build_response(200, response)

    except BadRequest as e:
        return build_response(400, {"error": str(e)})
    except Exception as e:
        # Avoid leaking internals; still log if CloudWatch is configured
        return build_response(500, {"error": "Internal server error"})


# ----- Local testing convenience -----
if __name__ == "__main__":
    # Example manual run
    example_event = {
        "items": [
            {"sku": "LAP-001", "unit_price": 999.99, "quantity": 1},
            {"sku": "MOU-001", "unit_price": 29.99, "quantity": 2},
        ],
        "discounts": [
            {"type": "PERCENT", "value": 10},
            {"type": "AMOUNT", "value": 5},
        ],
        "shipping": {"mode": "FLAT", "rate": 9.99, "free_over": 1000},
        "tax": {"rate_percent": 8.875, "apply_on_shipping": False},
    }
    print(json.dumps(json.loads(lambda_handler({"body": json.dumps(example_event)}, None)["body"]), indent=2))