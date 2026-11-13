"""Bounded official-SDK assertions for the agentgateway v1.7.0 MCP demo."""

import argparse
import asyncio
from contextlib import asynccontextmanager
from datetime import timedelta
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.parse import urlsplit

import httpx
from mcp import ClientSession, McpError, types
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
    check(info.st_uid == os.getuid(), "Token must be owned by you")
    check(not stat.S_IMODE(info.st_mode) & 0o077, "Token permissions must be restricted")
    value = path.read_text().strip()
    check(bool(value), "Token file is empty")
    return value


def routing_headers(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    check(path.is_absolute(), "Routing-header file must be an explicit absolute external path")
    restricted_directory(path.parent)
    info = path.lstat()
    check(
        stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
        and not stat.S_IMODE(info.st_mode) & 0o077,
        "Routing-header file must be a restricted regular file owned by you",
    )
    check(info.st_size <= 129, "Routing-header file is too large")
    nonce = path.read_text(encoding="ascii").strip()
    check(
        re.fullmatch(r"[A-Za-z0-9_-]{32,128}", nonce) is not None,
        "Routing-header file must contain one 32..128-character nonce",
    )
    return {"X-Agentgateway-MCP-Provisioning": nonce}


@asynccontextmanager
async def connect(
    url: str, bearer: str | None, *, routing_header_file: Path | None = None,
    rate_limit_observations: list[str | None] | None = None,
):
    headers = {"Authorization": "Bearer " + bearer} if bearer else {}
    headers.update(routing_headers(routing_header_file))

    async def retain_error_body(response: httpx.Response) -> None:
        # The SDK translates HTTP 404 into a generic session-termination error.
        # Preserve the exact HTTP failure for route-detachment assertions.
        if response.status_code == 404:
            response.raise_for_status()
        # The SDK raises HTTP errors before decoding MCP. Retain the body's
        # bytes before its streamed response closes so denial can be verified.
        if response.status_code in (400, 429):
            await response.aread()
        if (
            rate_limit_observations is not None and response.status_code == 200
            and response.request.method == "POST"
        ):
            request = types.JSONRPCMessage.model_validate_json(response.request.content).root
            if isinstance(request, types.JSONRPCRequest) and request.method == "initialize":
                rate_limit_observations.append(response.headers.get("x-ratelimit-limit"))

    async with httpx.AsyncClient(
        headers=headers, timeout=10, follow_redirects=False, trust_env=False,
        event_hooks={"response": [retain_error_body]},
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


class StatusMismatch(AssertionError):
    """A valid HTTP response has not converged to the expected policy status."""


async def rejected(
    url: str, bearer: str | None, label: str, *, routing_header_file: Path | None = None,
    expected_status: int = 401, quiet: bool = False,
) -> None:
    try:
        async with connect(url, bearer, routing_header_file=routing_header_file):
            raise AssertionError(f"{label}: unexpectedly authenticated")
    except BaseExceptionGroup as error:
        failures = list(leaves(error))
        check(
            bool(failures) and all(isinstance(failure, httpx.HTTPStatusError) for failure in failures),
            f"{label}: expected HTTP {expected_status}, got an unrelated failure",
        )
        statuses = [failure.response.status_code for failure in failures]
        if any(status != expected_status for status in statuses):
            raise StatusMismatch(f"{label}: expected HTTP {expected_status}, got {statuses}")
    except httpx.HTTPStatusError as error:
        if error.response.status_code != expected_status:
            raise StatusMismatch(f"{label}: expected HTTP {expected_status}, got {error.response.status_code}")
    if not quiet:
        print(f"PASS {label}: HTTP {expected_status}")


def authorization_error(error: BaseException) -> bool:
    if isinstance(error, McpError):
        data = error.error
    elif isinstance(error, httpx.HTTPStatusError) and error.response.status_code == 400:
        message = types.JSONRPCMessage.model_validate_json(error.response.content).root
        if not isinstance(message, types.JSONRPCError):
            return False
        data = message.error
    else:
        return False
    return data.code == -32602 and data.message == "unknown resource"


def quota_error(error: BaseException) -> bool:
    if isinstance(error, McpError):
        data = error.error
    elif isinstance(error, httpx.HTTPStatusError) and error.response.status_code == 429:
        message = types.JSONRPCMessage.model_validate_json(error.response.content).root
        if not isinstance(message, types.JSONRPCError):
            return False
        data = message.error
    else:
        return False
    return data.code == -32003 and data.message == "rate limit exceeded"


async def direct_denial(url: str, bearer: str, *, routing_header_file: Path | None = None) -> None:
    attempted = False
    call_returned = False
    try:
        async with connect(url, bearer, routing_header_file=routing_header_file) as (bob, _):
            attempted = True
            await bob.call_tool(INTERNAL, {"product_id": "star-widget"})
            call_returned = True
    except (McpError, httpx.HTTPStatusError, BaseExceptionGroup) as error:
        failures = list(leaves(error))
        check(
            attempted and not call_returned and bool(failures)
            and all(authorization_error(item) for item in failures),
            "Bob direct call: expected v1.7.0 authorization denial (-32602, unknown resource)",
        )
    else:
        raise AssertionError("Bob direct call was not denied by gateway authorization")
    print("PASS Bob direct call: authorization denial (-32602, unknown resource)")


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


async def authentication_assertions(args) -> None:
    directory = restricted_directory(args.token_directory)
    credentials = {name: token(directory, name) for name in ("alice", "bob", "invalid", "expired")}
    routing_file = getattr(args, "routing_header_file", None)
    await rejected(args.url, None, "missing JWT", routing_header_file=routing_file)
    await rejected(args.url, credentials["invalid"], "invalid-signature JWT", routing_header_file=routing_file)
    await rejected(args.url, credentials["expired"], "expired JWT", routing_header_file=routing_file)

    # Each phase gets a fresh bucket allowance; limits count transport requests.
    if args.phase == "all":
        await asyncio.sleep(args.rate_window_seconds + 1)
    async with connect(args.url, credentials["alice"], routing_header_file=routing_file) as (alice, protocol):
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

    if args.phase == "all":
        await asyncio.sleep(args.rate_window_seconds + 1)
    async with connect(args.url, credentials["bob"], routing_header_file=routing_file) as (bob, _):
        names = {tool.name for tool in (await bob.list_tools()).tools}
        check(names == TOOLS - {INTERNAL}, f"Bob tools: expected permitted tools, got {sorted(names)}")
        print(f"PASS Bob discovery: {sorted(names)}")
        await exact(bob, "calculator_add", {"a": 2, "b": 3}, {"result": 5.0})
        await exact(bob, "calculator_multiply", {"a": 6, "b": 7}, {"result": 42.0})
        await exact(bob, "catalog_lookup_product", {"product_id": "star-widget"}, PRODUCT)
    await direct_denial(args.url, credentials["bob"], routing_header_file=routing_file)

async def rate_assertions(args) -> None:
    directory = restricted_directory(args.token_directory)
    credentials = {name: token(directory, name) for name in ("alice", "bob")}
    routing_file = getattr(args, "routing_header_file", None)
    if args.phase == "all":
        await asyncio.sleep(args.rate_window_seconds + 1)
    async with connect(args.url, credentials["alice"], routing_header_file=routing_file) as (alice, _):
        async with connect(args.url, credentials["bob"], routing_header_file=routing_file) as (bob, _):
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


async def staged_assertions(args) -> None:
    directory = restricted_directory(args.token_directory)
    credentials = {name: token(directory, name) for name in ("alice", "invalid", "expired")}
    routing_file = getattr(args, "routing_header_file", None)
    for attempt in range(30):
        try:
            for bearer, label, status in (
                (None, "missing JWT", 401),
                (credentials["invalid"], "invalid-signature JWT", 401),
                (credentials["expired"], "expired JWT", 401),
                (credentials["alice"], "Alice staging backend unavailable", 503),
            ):
                await rejected(
                    args.url, bearer, label, routing_header_file=routing_file,
                    expected_status=status, quiet=True,
                )
        except StatusMismatch:
            if attempt == 29:
                raise AssertionError("Staged route did not converge to exact HTTP 401/503 within bounded polling")
            await asyncio.sleep(1)
        else:
            print("PASS staged JWT policy: missing/invalid/expired HTTP 401; Alice HTTP 503")
            return


async def quota_assertions(args) -> None:
    directory = restricted_directory(args.token_directory)
    bearer = token(directory, "alice")
    expected = None if args.expected_rate_limit == "absent" else args.expected_rate_limit
    for attempt in range(30):
        observations = []
        try:
            async with connect(
                args.url, bearer, routing_header_file=getattr(args, "routing_header_file", None),
                rate_limit_observations=observations,
            ):
                check(len(observations) == 1, "Quota readiness: missing authenticated initialization evidence")
        except (McpError, httpx.HTTPStatusError, BaseExceptionGroup) as error:
            failures = list(leaves(error))
            check(
                bool(failures) and all(quota_error(item) for item in failures),
                "Quota readiness encountered an unrelated transport/protocol failure",
            )
        else:
            if observations == [expected]:
                print(f"PASS quota propagation: x-ratelimit-limit={args.expected_rate_limit}")
                return
        if attempt < 29:
            await asyncio.sleep(1)
    raise AssertionError("Quota did not converge to the expected initialization header within bounded polling")


async def ready_assertions(args) -> None:
    directory = restricted_directory(args.token_directory)
    bearer = token(directory, "alice")
    for attempt in range(30):
        try:
            async with connect(
                args.url, bearer, routing_header_file=getattr(args, "routing_header_file", None)
            ) as (session, protocol):
                names = {tool.name for tool in (await session.list_tools()).tools}
                check(names == TOOLS, "Readiness: expected all four federated tools")
        except (httpx.HTTPStatusError, BaseExceptionGroup) as error:
            failures = list(leaves(error))
            check(
                bool(failures) and all(
                    isinstance(item, httpx.HTTPStatusError) and item.response.status_code == 503
                    for item in failures
                ),
                "MCP readiness encountered an unrelated transport/protocol failure",
            )
        else:
            print(f"PASS MCP readiness: all four federated tools; protocol {protocol}")
            return
        if attempt < 29:
            await asyncio.sleep(1)
    raise AssertionError("MCP backend did not become ready within bounded HTTP 503 polling")


async def detached_assertions(args) -> None:
    for attempt in range(30):
        try:
            await rejected(
                args.url, None, "detached MCP route", expected_status=404, quiet=True
            )
        except StatusMismatch:
            if attempt == 29:
                raise AssertionError("MCP route did not detach to exact HTTP 404 within bounded polling")
            await asyncio.sleep(1)
        else:
            print("PASS MCP route detached: unauthenticated SDK initialize HTTP 404")
            return


async def assertions(args) -> None:
    if args.phase == "detached":
        await detached_assertions(args)
    if args.phase == "quota":
        await quota_assertions(args)
    if args.phase == "staged":
        await staged_assertions(args)
    if args.phase == "ready":
        await ready_assertions(args)
    if args.phase in ("auth", "all"):
        await authentication_assertions(args)
    if args.phase in ("rate", "all"):
        await rate_assertions(args)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8080/mcp")
    parser.add_argument("--token-directory", "--token-dir", required=True, type=Path)
    parser.add_argument("--routing-header-file", type=Path)
    parser.add_argument(
        "--phase", choices=("detached", "staged", "ready", "auth", "rate", "quota", "all"),
        default="all",
    )
    parser.add_argument("--expected-rate-limit")
    parser.add_argument("--rate-capacity", type=int, default=30)
    parser.add_argument("--rate-window-seconds", type=float, default=30)
    parser.add_argument("--timeout-seconds", type=float, default=240)
    args = parser.parse_args()
    if args.phase == "quota":
        if args.expected_rate_limit != "absent":
            try:
                limit = int(args.expected_rate_limit)
            except (TypeError, ValueError):
                parser.error("Quota phase requires --expected-rate-limit absent or a positive integer")
            if not 1 <= limit <= 1000000:
                parser.error("Expected rate limit must be between 1 and 1000000")
            args.expected_rate_limit = str(limit)
    url = urlsplit(args.url)
    if (
        url.scheme not in ("http", "https") or url.hostname not in ("127.0.0.1", "localhost", "::1")
        or url.username or url.password or url.path != "/mcp" or url.query or url.fragment
        or not 8 <= args.rate_capacity <= 100
        or (args.phase == "all" and args.rate_capacity < 15)
        or not 1 <= args.rate_window_seconds <= 30
        or not 30 <= args.timeout_seconds <= 600
    ):
        parser.error(
            "Use a localhost /mcp URL, capacity 8..100 (at least 15 for all phases), "
            "refill 1..30s, timeout 30..600s"
        )
    try:
        asyncio.run(asyncio.wait_for(assertions(args), timeout=args.timeout_seconds))
    except (Exception, BaseExceptionGroup) as error:
        # HTTP exceptions can include request headers in third-party formatting.
        print(f"FAIL MCP assertions ({type(error).__name__}); no credentials logged", file=sys.stderr)
        if isinstance(error, AssertionError):
            print(str(error), file=sys.stderr)
        return 1
    print(f"PASS MCP {args.phase} assertions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
