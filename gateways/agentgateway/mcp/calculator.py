"""Deterministic calculator fixture; authorization is enforced by the gateway."""

import math
from typing import Annotated

from pydantic import BeforeValidator

from common import server


def finite_number(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("Expected a finite number; booleans and strings are not numbers")
    try:
        number = float(value)
    except (OverflowError, ValueError) as exc:
        raise ValueError("Expected a finite number") from exc
    if not math.isfinite(number):
        raise ValueError("Expected a finite number")
    return number


Number = Annotated[float, BeforeValidator(finite_number)]
mcp = server("calculator")


@mcp.tool()
def add(a: Number, b: Number) -> dict[str, float]:
    """Add two finite numbers."""
    return {"result": finite_number(a + b)}


@mcp.tool()
def multiply(a: Number, b: Number) -> dict[str, float]:
    """Multiply two finite numbers."""
    return {"result": finite_number(a * b)}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
