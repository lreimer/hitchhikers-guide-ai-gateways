"""Bundled fictional catalog, containing no real confidential information."""

import logging

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from pydantic import BaseModel

from common import app, run, server


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


class Product(BaseModel):
    product_id: str
    name: str
    price: float


class InternalNote(BaseModel):
    product_id: str
    note: str


mcp: MCPServer = server("catalog")
logger = logging.getLogger(__name__)


def product(product_id: str) -> dict[str, str | float]:
    try:
        return PRODUCTS[product_id]
    except KeyError as exc:
        raise ToolError(f"Unknown product: {product_id}") from exc


@mcp.tool()
def lookup_product(product_id: str) -> Product:
    """Return public information about a fictional product.

    Use the exact catalog ID: star-widget for Star Widget, or moon-gadget for
    Moon Gadget. Display names, plurals, and underscore-separated IDs do not match.
    """
    logger.info("tool_call=catalog.lookup_product")
    entry = product(product_id)
    return Product(product_id=product_id, name=entry["name"], price=entry["price"])


@mcp.tool()
def lookup_internal_note(product_id: str) -> InternalNote:
    """Return a synthetic internal note; the gateway controls access.

    Use the exact catalog ID: star-widget for Star Widget, or moon-gadget for
    Moon Gadget. Display names, plurals, and underscore-separated IDs do not match.
    """
    logger.info("tool_call=catalog.lookup_internal_note")
    return InternalNote(product_id=product_id, note=product(product_id)["internal_note"])


if __name__ == "__main__":
    run(mcp)
