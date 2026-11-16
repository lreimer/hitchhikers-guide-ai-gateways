"""Bundled fictional catalog, containing no real confidential information."""

from pydantic import BaseModel
from mcp.server.mcpserver.exceptions import ToolError

from common import server, transport_security


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


class ProductResult(BaseModel):
    product_id: str
    name: str
    price: float


class InternalNoteResult(BaseModel):
    product_id: str
    note: str


def product(product_id: str) -> dict[str, str | float]:
    try:
        return PRODUCTS[product_id]
    except KeyError as exc:
        raise ToolError(f"Unknown product: {product_id}") from exc


@mcp.tool()
def lookup_product(product_id: str) -> ProductResult:
    """Return public information about a fictional product."""
    entry = product(product_id)
    return ProductResult(product_id=product_id, name=entry["name"], price=entry["price"])


@mcp.tool()
def lookup_internal_note(product_id: str) -> InternalNoteResult:
    """Return a synthetic internal note; the gateway controls access."""
    return InternalNoteResult(product_id=product_id, note=product(product_id)["internal_note"])


if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=8000,
        streamable_http_path="/mcp",
        stateless_http=True,
        json_response=True,
        transport_security=transport_security("agentgateway-mcp-catalog"),
    )
