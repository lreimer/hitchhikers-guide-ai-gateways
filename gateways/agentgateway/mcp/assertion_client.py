"""Bounded official-SDK assertions for the agentgateway v1.7.0 MCP demo."""

import argparse
import asyncio
from contextlib import asynccontextmanager
from datetime import timedelta
import json
from pathlib import Path
import stat
import sys
from urllib.parse import urlsplit

import httpx
from mcp import ClientSession, McpError
from mcp.client.streamable_http import streamable_http_client

from jwt_tool import restricted_directory


TOOLS = {
    "calculator_add",
    "calculator_multiply",
    "catalog_lookup_product",
    "catalog_lookup_internal_note",
}
INTERNAL = "catalog_lookup_internal_note"
PRODUCT = {"product_id": "star-widget", "name": "Star Widget", "price": 12.5}
NOTE = {
    "product_id": "star-widget",
    "note": "Synthetic note: next batch is painted violet.",
}


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def token(directory: Path, identity: str) -> str:
    path = directory / f"{identity}.jwt"
    info = path.lstat()
    check(stat.S_ISREG(info.st_mode), "Token must be a regular, non-symlink file")
    check(not stat.S_IMODE(info.st_mode) & 0o077, "Token permissions must be restricted")
    value = path.read_text().strip()
    check(bool(value), "Token file is empty")
    return value


@asynccontextmanager
async def connect(url: str, bearer: str | None):
    headers = {"Authorization": "Bearer " + bearer} if bearer else {}
    async with httpx.AsyncClient(
        headers=headers, timeout=10, follow_redirects=False, trust_env=False
    ) as client:
        async with streamable_http_client(url, http_client=client) as (read, write, _):
            async with ClientSession(
                read, write, read_timeout_seconds=timedelta(seconds=10)
            ) as session:
                initialized = await session.initialize()
                yield session, initialized.protocolVersion


def leaves(error: BaseException):
    if isinstance(error, BaseExceptionGroup):
        for nested in error.exceptions:
            yield from leaves(nested)
    else:
        yield error


async def rejected(url: str, bearer: str | None, label: str) -> None:
    try:
        async with connect(url, bearer):
            raise AssertionError(f"{label}: unexpectedly authenticated")
    except BaseExceptionGroup as error:
        failures = list(leaves(error))
        check(
            bool(failures) and all(
                isinstance(failure, httpx.HTTPStatusError)
                and failure.response.status_code == 401
                for failure in failures
            ),
            f"{label}: expected HTTP 401, got an unrelated failure",
        )
    except httpx.HTTPStatusError as error:
        check(error.response.status_code == 401, f"{label}: expected HTTP 401")
    print(f"PASS {label}: HTTP 401")


def result_value(result) -> dict:
    check(not result.isError, "Unexpected tool-level error")
    if result.structuredContent is not None:
        return result.structuredContent
    check(len(result.content) == 1, "Expected exactly one JSON result block")
    check(result.content[0].type == "text", "Expected a text JSON result block")
    return json.loads(result.content[0].text)


async def exact(session, name: str, arguments: dict, expected: dict) -> None:
    actual = result_value(await session.call_tool(name, arguments))
    check(actual == expected, f"{name}: expected {expected!r}, got {actual!r}")
    print(f"PASS {name}: {actual}")


def throttled(result) -> bool:
    if not result.isError:
        return False
    text = " ".join(
        block.text for block in result.content if block.type == "text"
    )
    check(
        text.startswith("rate limit exceeded"),
        "Unexpected tool error while checking rate limits",
    )
    return True


async def rate_call(session):
    try:
        result = await session.call_tool("calculator_add", {"a": 2, "b": 3})
    except McpError as error:
        check(
            error.error.code == -32003
            and error.error.message == "rate limit exceeded",
            "Unexpected JSON-RPC error while checking rate limits",
        )
        return True
    if throttled(result):
        return True
    check(result_value(result) == {"result": 5.0}, "Wrong calculator result during rate test")
    return False


async def assertions(args) -> None:
    directory = restricted_directory(args.token_directory)
    credentials = {name: token(directory, name) for name in ("alice", "bob", "invalid", "expired")}
    await rejected(args.url, None, "missing JWT")
    await rejected(args.url, credentials["invalid"], "invalid-signature JWT")
    await rejected(args.url, credentials["expired"], "expired JWT")

    # Each phase gets a fresh bucket allowance; limits count transport requests.
    await asyncio.sleep(args.rate_window_seconds + 1)
    async with connect(args.url, credentials["alice"]) as (alice, protocol):
        names = {tool.name for tool in (await alice.list_tools()).tools}
        check(names == TOOLS, f"Alice tools: expected {sorted(TOOLS)}, got {sorted(names)}")
        print(f"PASS Alice discovery: {sorted(names)}; MCP protocol {protocol}")
        await exact(alice, "calculator_add", {"a": 2, "b": 3}, {"result": 5.0})
        await exact(alice, "calculator_multiply", {"a": 6, "b": 7}, {"result": 42.0})
        await exact(alice, "catalog_lookup_product", {"product_id": "star-widget"}, PRODUCT)
        await exact(alice, INTERNAL, {"product_id": "star-widget"}, NOTE)
        for name, arguments, fragment in (
            ("calculator_add", {"a": True, "b": 3}, "finite number"),
            ("calculator_multiply", {"a": "3", "b": 2}, "finite number"),
            ("catalog_lookup_product", {"product_id": "missing"}, "Unknown product: missing"),
            (INTERNAL, {"product_id": "missing"}, "Unknown product: missing"),
        ):
            result = await alice.call_tool(name, arguments)
            text = " ".join(block.text for block in result.content if block.type == "text")
            check(result.isError and fragment in text, f"{name}: expected specific input/tool error")
            print(f"PASS {name}: expected input/tool error ({fragment})")

    await asyncio.sleep(args.rate_window_seconds + 1)
    async with connect(args.url, credentials["bob"]) as (bob, _):
        names = {tool.name for tool in (await bob.list_tools()).tools}
        check(names == TOOLS - {INTERNAL}, f"Bob tools: expected permitted tools, got {sorted(names)}")
        print(f"PASS Bob discovery: {sorted(names)}")
        await exact(bob, "calculator_add", {"a": 2, "b": 3}, {"result": 5.0})
        await exact(bob, "catalog_lookup_product", {"product_id": "star-widget"}, PRODUCT)
        try:
            await bob.call_tool(INTERNAL, {"product_id": "star-widget"})
        except McpError as error:
            check(
                error.error.code == -32602 and error.error.message == "unknown resource",
                "Bob direct call: expected v1.7.0 authorization denial (-32602, unknown resource)",
            )
        else:
            raise AssertionError("Bob direct call was not denied by gateway authorization")
        print("PASS Bob direct call: authorization denial (-32602, unknown resource)")

    await asyncio.sleep(args.rate_window_seconds + 1)
    async with connect(args.url, credentials["alice"]) as (alice, _):
        async with connect(args.url, credentials["bob"]) as (bob, _):
            limited = False
            for _ in range(2 * args.rate_capacity + 4):
                if await rate_call(alice):
                    limited = True
                    break
            check(limited, "Alice did not reach the configured per-user rate limit within request bound")
            print("PASS Alice throttled: specific MCP rate-limit error")
            await exact(bob, "calculator_add", {"a": 2, "b": 3}, {"result": 5.0})
            recovered = False
            for _ in range(8):
                await asyncio.sleep(args.rate_window_seconds / 4 + 0.25)
                if not await rate_call(alice):
                    recovered = True
                    break
            check(recovered, "Alice rate bucket did not recover within bounded refill polling")
            print("PASS Alice refill recovery; Bob remained usable")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8080/mcp")
    parser.add_argument("--token-directory", required=True, type=Path)
    parser.add_argument("--rate-capacity", type=int, default=30)
    parser.add_argument("--rate-window-seconds", type=float, default=10)
    parser.add_argument("--timeout-seconds", type=float, default=240)
    args = parser.parse_args()
    url = urlsplit(args.url)
    if (
        url.scheme not in ("http", "https") or url.hostname not in ("127.0.0.1", "localhost", "::1")
        or url.username or url.password or url.path != "/mcp" or url.query or url.fragment
        or not 15 <= args.rate_capacity <= 100
        or not 1 <= args.rate_window_seconds <= 30
        or not 30 <= args.timeout_seconds <= 600
    ):
        parser.error("Use a localhost /mcp URL, capacity 15..100, refill 1..30s, timeout 30..600s")
    try:
        asyncio.run(asyncio.wait_for(assertions(args), timeout=args.timeout_seconds))
    except (Exception, BaseExceptionGroup) as error:
        # HTTP exceptions can include request headers in third-party formatting.
        print(f"FAIL MCP assertions ({type(error).__name__}); no credentials logged", file=sys.stderr)
        if isinstance(error, AssertionError):
            print(str(error), file=sys.stderr)
        return 1
    print("PASS all MCP authentication, federation, authorization, and rate assertions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
