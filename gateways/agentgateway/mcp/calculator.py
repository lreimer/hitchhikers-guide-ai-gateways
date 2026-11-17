"""Deterministic calculator fixture; authorization is enforced by the gateway."""

import logging
import math
from typing import Annotated

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from pydantic import BaseModel, BeforeValidator

from common import app, run, server


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


def finite_result(value: float) -> float:
    if not math.isfinite(value):
        raise ToolError("Expected a finite number")
    return value


Number = Annotated[float, BeforeValidator(finite_number)]


class Calculation(BaseModel):
    result: float


mcp: MCPServer = server("calculator")
logger = logging.getLogger(__name__)


@mcp.tool()
def add(a: Number, b: Number) -> Calculation:
    """Add two finite numbers."""
    logger.info("tool_call=calculator.add")
    return Calculation(result=finite_result(a + b))


@mcp.tool()
def multiply(a: Number, b: Number) -> Calculation:
    """Multiply two finite numbers."""
    logger.info("tool_call=calculator.multiply")
    return Calculation(result=finite_result(a * b))


if __name__ == "__main__":
    run(mcp)
