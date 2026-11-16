"""Deterministic calculator fixture; authorization is enforced by the gateway."""

import math
from typing import Annotated, Any

from pydantic import BaseModel, Field
from mcp.server.mcpserver.exceptions import ToolError

from common import server, transport_security


Number = Annotated[
    Any,
    Field(description="A finite number", json_schema_extra={"type": "number"}),
]


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


mcp = server("calculator")


class CalculationResult(BaseModel):
    result: float


def checked_number(value: object) -> float:
    try:
        return finite_number(value)
    except ValueError as exc:
        raise ToolError(str(exc)) from exc


@mcp.tool()
def add(a: Number, b: Number) -> CalculationResult:
    """Add two finite numbers."""
    return CalculationResult(result=checked_number(checked_number(a) + checked_number(b)))


@mcp.tool()
def multiply(a: Number, b: Number) -> CalculationResult:
    """Multiply two finite numbers."""
    return CalculationResult(result=checked_number(checked_number(a) * checked_number(b)))


if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=8000,
        streamable_http_path="/mcp",
        stateless_http=True,
        json_response=True,
        transport_security=transport_security("agentgateway-mcp-calculator"),
    )
