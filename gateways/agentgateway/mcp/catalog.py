"""Bundled fictional catalog, containing no real confidential information."""

from common import server


PRODUCTS = {
    "star-widget": {
        "name": "Star Widget",
        "price": 12.5,
        "internal_note": "Synthetic note: next batch is painted violet.",
    },
    "moon-gadget": {
        "name": "Moon Gadget",
        "price": 24.0,
        "internal_note": "Synthetic note: demo-only lunar packaging.",
    },
}
mcp = server("catalog")


def product(product_id: str) -> dict:
    try:
        return PRODUCTS[product_id]
    except KeyError as exc:
        raise ValueError(f"Unknown product: {product_id}") from exc


@mcp.tool()
def lookup_product(product_id: str) -> dict:
    """Return public information about a fictional product."""
    entry = product(product_id)
    return {
        "product_id": product_id,
        "name": entry["name"],
        "price": entry["price"],
    }


@mcp.tool()
def lookup_internal_note(product_id: str) -> dict:
    """Return a synthetic internal note; the gateway controls access."""
    return {"product_id": product_id, "note": product(product_id)["internal_note"]}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
