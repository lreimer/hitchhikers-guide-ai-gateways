"""Focused standard-library tests; run with the MCP locked Python environment."""

import asyncio
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import shutil
import sys
import unittest
from unittest.mock import patch
import uuid


MCP_DIR = Path(__file__).resolve().parents[1] / "gateways" / "agentgateway" / "mcp"
sys.path.insert(0, str(MCP_DIR))

import httpx
import jwt
from mcp import ClientSession, McpError, types
from mcp.client.streamable_http import streamable_http_client
from mcp.server.fastmcp.exceptions import ToolError

import assertion_client
import calculator
import catalog
import jwt_tool


class CalculatorTests(unittest.IsolatedAsyncioTestCase):
    async def test_exact_results(self):
        for name, arguments, expected in (
            ("add", {"a": 2, "b": 3}, {"result": 5.0}),
            ("multiply", {"a": 6, "b": 7}, {"result": 42.0}),
            ("add", {"a": -2.5, "b": 1}, {"result": -1.5}),
        ):
            with self.subTest(name=name, arguments=arguments):
                _, structured = await calculator.mcp.call_tool(name, arguments)
                self.assertEqual(structured, expected)

    async def test_rejects_bool_string_nonfinite_and_overflow(self):
        for value in (True, False, "2", None, float("nan"), float("inf"), -float("inf"), 10**400):
            for argument in ("a", "b"):
                with self.subTest(value=repr(value), argument=argument):
                    args = {"a": 2, "b": 3, argument: value}
                    with self.assertRaisesRegex(ToolError, "finite number"):
                        await calculator.mcp.call_tool("add", args)
        for name in ("add", "multiply"):
            with self.subTest(name=name), self.assertRaisesRegex(ToolError, "finite number"):
                await calculator.mcp.call_tool(name, {"a": 1e308, "b": 1e308})

    async def test_missing_input_is_not_fabricated(self):
        with self.assertRaisesRegex(ToolError, "Field required"):
            await calculator.mcp.call_tool("add", {"a": 2})


class CatalogTests(unittest.IsolatedAsyncioTestCase):
    async def test_public_result_has_no_internal_note(self):
        _, result = await catalog.mcp.call_tool("lookup_product", {"product_id": "star-widget"})
        self.assertEqual(result, assertion_client.PRODUCT)
        self.assertNotIn("internal_note", result)

    async def test_synthetic_internal_result(self):
        _, result = await catalog.mcp.call_tool("lookup_internal_note", {"product_id": "star-widget"})
        self.assertEqual(result, assertion_client.NOTE)

    async def test_unknown_products_are_clear_tool_errors(self):
        for name in ("lookup_product", "lookup_internal_note"):
            with self.subTest(name=name), self.assertRaisesRegex(ToolError, "Unknown product: missing"):
                await catalog.mcp.call_tool(name, {"product_id": "missing"})

    async def test_second_bundled_product(self):
        _, result = await catalog.mcp.call_tool("lookup_product", {"product_id": "moon-gadget"})
        self.assertEqual(result, {"product_id": "moon-gadget", "name": "Moon Gadget", "price": 24.0})


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_official_sdk_streamable_http_and_readiness(self):
        for backend, expected in (
            (calculator, {"add", "multiply"}),
            (catalog, {"lookup_product", "lookup_internal_note"}),
        ):
            with self.subTest(backend=backend.__name__):
                app = backend.mcp.streamable_http_app()
                async with app.router.lifespan_context(app):
                    async with httpx.AsyncClient(
                        transport=httpx.ASGITransport(app=app), base_url="http://backend"
                    ) as client:
                        response = await client.get("/readyz")
                        self.assertEqual(response.status_code, 200)
                        self.assertEqual(response.json(), {"status": "ready"})
                        async with streamable_http_client(
                            "http://backend/mcp", http_client=client
                        ) as (read, write, get_id):
                            async with ClientSession(read, write) as session:
                                await session.initialize()
                                self.assertIsNone(get_id())
                                tools = (await session.list_tools()).tools
                                self.assertEqual({tool.name for tool in tools}, expected)
                                if backend is calculator:
                                    good = await session.call_tool("add", {"a": 2, "b": 3})
                                    self.assertEqual(assertion_client.result_value(good), {"result": 5.0})
                                    bad = await session.call_tool("add", {"a": True, "b": 3})
                                    self.assertTrue(bad.isError)
                                    self.assertIn("finite number", bad.content[0].text)
                                else:
                                    bad = await session.call_tool("lookup_product", {"product_id": "missing"})
                                    self.assertTrue(bad.isError)
                                    self.assertIn("Unknown product: missing", bad.content[0].text)


class JwtTests(unittest.TestCase):
    def setUp(self):
        self.directory = MCP_DIR / (".test-artifacts-" + uuid.uuid4().hex)
        self.directory.mkdir(mode=0o700)
        self.files = {}
        self.modes = {}

    def tearDown(self):
        shutil.rmtree(self.directory)

    def generate(self):
        import os
        import stat
        from types import SimpleNamespace

        original_exists = Path.exists
        original_read = Path.read_bytes
        original_lstat = Path.lstat
        private = self.directory / "private.pem"

        def exists(path):
            return path in self.files if path == private else original_exists(path)

        def read(path):
            return self.files[path] if path == private else original_read(path)

        def lstat(path):
            if path == private:
                return SimpleNamespace(
                    st_mode=stat.S_IFREG | self.modes.get(path, 0o600), st_uid=os.getuid()
                )
            return original_lstat(path)

        def write(path, data):
            # Real signing material stays in memory, even if a test is interrupted.
            self.files[path] = data

        with patch.object(jwt_tool, "restricted_directory", return_value=self.directory), patch.object(
            jwt_tool, "write_private", side_effect=write
        ), patch.object(Path, "exists", exists), patch.object(Path, "read_bytes", read), patch.object(
            Path, "lstat", lstat
        ):
            jwt_tool.generate(self.directory, jwt_tool.ISSUER, jwt_tool.AUDIENCE, 900)

    def token(self, identity):
        return self.files[self.directory / f"{identity}.jwt"].decode().strip()

    def test_rsa_jwks_claims_rejections_and_permissions(self):
        output = io.StringIO()
        with redirect_stdout(output):
            self.generate()
        self.assertEqual(output.getvalue(), "")
        jwks = json.loads(self.files[self.directory / "jwks.json"])
        public_key = jwt.PyJWK.from_dict(jwks["keys"][0]).key
        for identity in ("alice", "bob"):
            claims = jwt.decode(
                self.token(identity), public_key,
                algorithms=["RS256"], issuer=jwt_tool.ISSUER, audience=jwt_tool.AUDIENCE,
            )
            self.assertEqual(claims["sub"], identity)
            self.assertLessEqual(claims["exp"] - claims["iat"], 900)
        with self.assertRaises(jwt.ExpiredSignatureError):
            jwt.decode(self.token("expired"), public_key,
                       algorithms=["RS256"], audience=jwt_tool.AUDIENCE)
        with self.assertRaises(jwt.InvalidSignatureError):
            jwt.decode(self.token("invalid"), public_key,
                       algorithms=["RS256"], audience=jwt_tool.AUDIENCE)
        self.assertEqual(list(self.directory.iterdir()), [])
        permission_file = self.directory / "permission-check"
        jwt_tool.write_private(permission_file, b"nonsecret permission fixture")
        self.assertEqual(permission_file.stat().st_mode & 0o777, 0o600)

    def test_renewal_keeps_provisioned_public_key(self):
        self.generate()
        key = self.files[self.directory / "private.pem"]
        jwks = self.files[self.directory / "jwks.json"]
        self.generate()
        self.assertEqual(self.files[self.directory / "private.pem"], key)
        self.assertEqual(self.files[self.directory / "jwks.json"], jwks)

    def test_expired_fixture_exceeds_gateway_clock_leeway(self):
        from datetime import datetime, timezone

        now = int(datetime.now(timezone.utc).timestamp())
        with patch.object(jwt_tool.time, "time", return_value=now):
            self.generate()
        claims = jwt.decode(self.token("expired"), options={"verify_signature": False})
        self.assertEqual(claims["iat"], now - 240)
        self.assertEqual(claims["exp"], now - 120)
        public = jwt.PyJWK.from_dict(
            json.loads(self.files[self.directory / "jwks.json"])["keys"][0]
        ).key
        with self.assertRaises(jwt.ExpiredSignatureError):
            jwt.decode(
                self.token("expired"), public, algorithms=["RS256"],
                issuer=jwt_tool.ISSUER, audience=jwt_tool.AUDIENCE, leeway=60,
            )

    def test_rejects_repository_and_relative_directory(self):
        for directory in (MCP_DIR, Path("relative")):
            with self.subTest(directory=directory), self.assertRaises(ValueError):
                jwt_tool.restricted_directory(directory)

    def test_container_layout_without_repository_marker(self):
        with patch.object(jwt_tool, "__file__", "/app/jwt_tool.py"):
            self.assertEqual(jwt_tool.restricted_directory(self.directory), self.directory)
            with self.assertRaisesRegex(ValueError, "outside"):
                jwt_tool.restricted_directory(Path("/app/credentials"))

    def test_rejects_unsafe_existing_private_file(self):
        private = self.directory / "private.pem"
        self.files[private] = b"not a key"
        self.modes[private] = 0o644
        with self.assertRaisesRegex(ValueError, "private"):
            self.generate()


class ClientCliTests(unittest.TestCase):
    def test_rate_phase_accepts_token_dir_alias_and_burst_twelve(self):
        from unittest.mock import AsyncMock

        argv = [
            "assertion_client.py", "--token-dir", "/explicit-external-keys",
            "--phase", "rate", "--rate-capacity", "12",
            "--routing-header-file", "/explicit-external-keys/provisioning",
        ]
        assertions = AsyncMock()
        with patch.object(sys, "argv", argv), patch.object(assertion_client, "assertions", assertions):
            with redirect_stdout(io.StringIO()):
                self.assertEqual(assertion_client.main(), 0)
        args = assertions.await_args.args[0]
        self.assertEqual(args.token_directory, Path("/explicit-external-keys"))
        self.assertEqual(args.rate_capacity, 12)
        self.assertEqual(args.phase, "rate")
        self.assertEqual(args.routing_header_file, Path("/explicit-external-keys/provisioning"))

    def test_routing_header_reads_restricted_external_file_without_output(self):
        import os
        import stat
        from types import SimpleNamespace

        path = Path("/explicit-external-keys/provisioning")
        info = SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=os.getuid(), st_size=65)
        output = io.StringIO()
        with patch.object(assertion_client, "restricted_directory", return_value=path.parent), patch.object(
            Path, "lstat", return_value=info
        ), patch.object(Path, "read_text", return_value="a" * 64 + "\n"), redirect_stdout(output):
            headers = assertion_client.routing_headers(path)
        self.assertEqual(headers, {"X-Agentgateway-MCP-Provisioning": "a" * 64})
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(assertion_client.routing_headers(None), {})

    def test_routing_header_rejects_unsafe_file_and_multiline_nonce(self):
        import os
        import stat
        from types import SimpleNamespace

        path = Path("/explicit-external-keys/provisioning")
        for mode, owner, value in (
            (stat.S_IFREG | 0o644, os.getuid(), "a" * 64),
            (stat.S_IFLNK | 0o600, os.getuid(), "a" * 64),
            (stat.S_IFREG | 0o600, os.getuid() + 1, "a" * 64),
            (stat.S_IFREG | 0o600, os.getuid(), "a" * 32 + "\n" + "b" * 32),
        ):
            info = SimpleNamespace(st_mode=mode, st_uid=owner, st_size=len(value))
            with patch.object(assertion_client, "restricted_directory", return_value=path.parent), patch.object(
                Path, "lstat", return_value=info
            ), patch.object(Path, "read_text", return_value=value):
                with self.assertRaises(AssertionError):
                    assertion_client.routing_headers(path)
        with self.assertRaisesRegex(AssertionError, "absolute"):
            assertion_client.routing_headers(Path("relative"))


class AssertionClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_successful_forbidden_call_cannot_be_masked_by_cleanup_denial(self):
        from contextlib import asynccontextmanager
        from unittest.mock import AsyncMock

        session = AsyncMock()
        session.call_tool.return_value = types.CallToolResult(
            isError=False, content=[types.TextContent(type="text", text="synthetic internal note")]
        )

        @asynccontextmanager
        async def connection(url, bearer, **kwargs):
            yield session, "2025-11-25"
            raise McpError(types.ErrorData(code=-32602, message="unknown resource"))

        with patch.object(assertion_client, "connect", connection):
            with self.assertRaisesRegex(AssertionError, "expected v1.7.0 authorization denial"):
                await assertion_client.direct_denial("http://localhost/mcp", "local-test-value")
        session.call_tool.assert_awaited_once_with(
            assertion_client.INTERNAL, {"product_id": "star-widget"}
        )

    async def test_real_sdk_detachment_retries_401_then_requires_404(self):
        from argparse import Namespace
        from starlette.applications import Starlette
        from starlette.responses import Response
        from starlette.routing import Route
        from unittest.mock import AsyncMock

        attempts = []

        async def gate(request):
            self.assertNotIn("authorization", request.headers)
            attempts.append(request.method)
            return Response(status_code=401 if len(attempts) == 1 else 404)

        app = Starlette(routes=[Route("/mcp", gate, methods=["POST", "GET", "DELETE"])])
        client_class = httpx.AsyncClient

        def client(**kwargs):
            return client_class(transport=httpx.ASGITransport(app=app), **kwargs)

        with patch.object(assertion_client.httpx, "AsyncClient", side_effect=client), patch.object(
            assertion_client.asyncio, "sleep", AsyncMock()
        ), patch.object(assertion_client, "token", side_effect=AssertionError("Tokens must not be read")):
            with redirect_stdout(io.StringIO()):
                await assertion_client.detached_assertions(
                    Namespace(url="http://localhost/mcp", token_directory=Path("/not-needed"))
                )
        self.assertEqual(attempts, ["POST", "POST"])

    async def test_detachment_rejects_generic_transport_failure(self):
        from argparse import Namespace
        from contextlib import asynccontextmanager

        @asynccontextmanager
        async def connection(url, bearer, **kwargs):
            raise ExceptionGroup("transport", [httpx.ConnectError("unreachable")])
            yield

        with patch.object(assertion_client, "connect", connection):
            with self.assertRaisesRegex(AssertionError, "unrelated"):
                await assertion_client.detached_assertions(Namespace(url="http://localhost/mcp"))

    async def test_real_sdk_ready_retries_503_then_discovers_exact_tools(self):
        from argparse import Namespace
        from starlette.middleware.base import BaseHTTPMiddleware
        from starlette.responses import Response
        from unittest.mock import AsyncMock

        backend = calculator.server("ready-convergence-test")
        for name in assertion_client.TOOLS:
            @backend.tool(name=name)
            def fixture() -> str:
                return "ready"

        initializations = []

        async def gate(request, call_next):
            if request.method == "POST":
                message = types.JSONRPCMessage.model_validate_json(await request.body()).root
                if isinstance(message, types.JSONRPCRequest) and message.method == "initialize":
                    initializations.append(message.id)
                    if len(initializations) == 1:
                        return Response(status_code=503)
            return await call_next(request)

        app = backend.streamable_http_app()
        app.add_middleware(BaseHTTPMiddleware, dispatch=gate)
        client_class = httpx.AsyncClient

        def client(**kwargs):
            return client_class(transport=httpx.ASGITransport(app=app), **kwargs)

        async with app.router.lifespan_context(app):
            with patch.object(assertion_client.httpx, "AsyncClient", side_effect=client), patch.object(
                assertion_client, "restricted_directory", return_value=MCP_DIR
            ), patch.object(assertion_client, "token", return_value="alice"), patch.object(
                assertion_client.asyncio, "sleep", AsyncMock()
            ), redirect_stdout(io.StringIO()):
                await assertion_client.ready_assertions(
                    Namespace(token_directory=MCP_DIR, url="http://localhost/mcp")
                )
        self.assertEqual(len(initializations), 2)

    async def test_ready_generic_transport_failure_is_not_retried(self):
        from argparse import Namespace
        from contextlib import asynccontextmanager

        attempts = []

        @asynccontextmanager
        async def connection(url, bearer, **kwargs):
            attempts.append(bearer)
            raise ExceptionGroup("transport", [httpx.ConnectError("unreachable")])
            yield

        with patch.object(assertion_client, "restricted_directory", return_value=MCP_DIR), patch.object(
            assertion_client, "token", return_value="alice"
        ), patch.object(assertion_client, "connect", connection):
            with self.assertRaisesRegex(AssertionError, "unrelated"):
                await assertion_client.ready_assertions(
                    Namespace(token_directory=MCP_DIR, url="http://localhost/mcp")
                )
        self.assertEqual(attempts, ["alice"])

    async def test_real_sdk_quota_http429_converges_to_expected_header(self):
        from argparse import Namespace
        from starlette.middleware.base import BaseHTTPMiddleware
        from starlette.responses import JSONResponse
        from unittest.mock import AsyncMock

        initializations = []

        async def gate(request, call_next):
            if request.method == "POST":
                message = types.JSONRPCMessage.model_validate_json(await request.body()).root
                if isinstance(message, types.JSONRPCRequest) and message.method == "initialize":
                    initializations.append(message.id)
                    if len(initializations) == 1:
                        error = types.JSONRPCError(
                            jsonrpc="2.0", id=message.id,
                            error=types.ErrorData(code=-32003, message="rate limit exceeded"),
                        )
                        return JSONResponse(
                            error.model_dump(), status_code=429,
                            headers={"x-ratelimit-limit": "30", "x-ratelimit-remaining": "0"},
                        )
            response = await call_next(request)
            response.headers["x-ratelimit-limit"] = "240"
            return response

        app = calculator.server("quota-convergence-test").streamable_http_app()
        app.add_middleware(BaseHTTPMiddleware, dispatch=gate)
        client_class = httpx.AsyncClient

        def client(**kwargs):
            return client_class(transport=httpx.ASGITransport(app=app), **kwargs)

        async with app.router.lifespan_context(app):
            with patch.object(assertion_client.httpx, "AsyncClient", side_effect=client), patch.object(
                assertion_client, "restricted_directory", return_value=MCP_DIR
            ), patch.object(assertion_client, "token", return_value="alice"), patch.object(
                assertion_client.asyncio, "sleep", AsyncMock()
            ), redirect_stdout(io.StringIO()):
                await assertion_client.quota_assertions(
                    Namespace(token_directory=MCP_DIR, url="http://localhost/mcp", expected_rate_limit="240")
                )
        self.assertEqual(len(initializations), 2)

    async def test_quota_phase_retries_only_specific_old_policy_throttling(self):
        from argparse import Namespace
        from contextlib import asynccontextmanager
        from unittest.mock import AsyncMock

        attempts = []

        @asynccontextmanager
        async def connection(url, bearer, **kwargs):
            attempts.append(bearer)
            if len(attempts) == 1:
                raise McpError(types.ErrorData(code=-32003, message="rate limit exceeded"))
            kwargs["rate_limit_observations"].append("240")
            yield None, "2025-11-25"

        with patch.object(assertion_client, "restricted_directory", return_value=MCP_DIR), patch.object(
            assertion_client, "token", return_value="alice"
        ), patch.object(assertion_client, "connect", connection), patch.object(
            assertion_client.asyncio, "sleep", AsyncMock()
        ), redirect_stdout(io.StringIO()):
            await assertion_client.quota_assertions(
                Namespace(token_directory=MCP_DIR, url="http://localhost/mcp", expected_rate_limit="240")
            )
        self.assertEqual(attempts, ["alice", "alice"])

    async def test_quota_http_error_requires_exact_mcp_payload(self):
        for message, expected in (("rate limit exceeded", True), ("upstream error", False)):
            response = httpx.Response(
                429, request=httpx.Request("POST", "http://localhost/mcp"),
                json={"jsonrpc": "2.0", "id": 1, "error": {"code": -32003, "message": message}},
            )
            error = httpx.HTTPStatusError("throttled", request=response.request, response=response)
            self.assertEqual(assertion_client.quota_error(error), expected)
        self.assertFalse(assertion_client.quota_error(httpx.ConnectError("unreachable")))

    async def test_quota_phase_polls_for_exact_initialization_header(self):
        from argparse import Namespace
        from contextlib import asynccontextmanager
        from unittest.mock import AsyncMock

        attempts = []

        @asynccontextmanager
        async def connection(url, bearer, **kwargs):
            attempts.append(bearer)
            kwargs["rate_limit_observations"].append(None if len(attempts) == 1 else "30")
            yield None, "2025-11-25"

        with patch.object(assertion_client, "restricted_directory", return_value=MCP_DIR), patch.object(
            assertion_client, "token", return_value="alice"
        ), patch.object(assertion_client, "connect", connection), patch.object(
            assertion_client.asyncio, "sleep", AsyncMock()
        ), redirect_stdout(io.StringIO()):
            await assertion_client.quota_assertions(
                Namespace(token_directory=MCP_DIR, url="http://localhost/mcp", expected_rate_limit="30")
            )
        self.assertEqual(attempts, ["alice", "alice"])

    async def test_sdk_initialization_rate_header_capture(self):
        from starlette.middleware.base import BaseHTTPMiddleware

        async def headers(request, call_next):
            response = await call_next(request)
            response.headers["x-ratelimit-limit"] = "240"
            return response

        app = calculator.server("quota-header-test").streamable_http_app()
        app.add_middleware(BaseHTTPMiddleware, dispatch=headers)
        client_class = httpx.AsyncClient

        def client(**kwargs):
            return client_class(transport=httpx.ASGITransport(app=app), **kwargs)

        observations = []
        async with app.router.lifespan_context(app):
            with patch.object(assertion_client.httpx, "AsyncClient", side_effect=client):
                async with assertion_client.connect(
                    "http://localhost/mcp", "local-test-value",
                    rate_limit_observations=observations,
                ):
                    self.assertEqual(observations, ["240"])

    async def test_staged_phase_requires_exact_statuses_and_bounded_retry(self):
        from argparse import Namespace
        from unittest.mock import AsyncMock

        rejected = AsyncMock(side_effect=[
            assertion_client.StatusMismatch("not propagated"), None, None, None, None
        ])
        with patch.object(assertion_client, "restricted_directory", return_value=MCP_DIR), patch.object(
            assertion_client, "token", side_effect=lambda directory, identity: identity
        ), patch.object(assertion_client, "rejected", rejected), patch.object(
            assertion_client.asyncio, "sleep", AsyncMock()
        ), redirect_stdout(io.StringIO()):
            await assertion_client.staged_assertions(
                Namespace(token_directory=MCP_DIR, url="http://localhost/mcp")
            )
        statuses = [entry.kwargs["expected_status"] for entry in rejected.await_args_list]
        self.assertEqual(statuses, [401, 401, 401, 401, 503])

    async def test_staged_phase_rejects_unrelated_failures_without_retry(self):
        from argparse import Namespace
        from unittest.mock import AsyncMock

        rejected = AsyncMock(side_effect=AssertionError("unrelated transport failure"))
        with patch.object(assertion_client, "restricted_directory", return_value=MCP_DIR), patch.object(
            assertion_client, "token", side_effect=lambda directory, identity: identity
        ), patch.object(assertion_client, "rejected", rejected):
            with self.assertRaisesRegex(AssertionError, "unrelated"):
                await assertion_client.staged_assertions(
                    Namespace(token_directory=MCP_DIR, url="http://localhost/mcp")
                )
        self.assertEqual(rejected.await_count, 1)

    async def test_auth_phase_calls_all_three_permitted_bob_tools(self):
        from argparse import Namespace
        from contextlib import asynccontextmanager
        from unittest.mock import AsyncMock

        class Session:
            def __init__(self, identity):
                self.identity = identity

            async def list_tools(self):
                names = assertion_client.TOOLS
                if self.identity == "bob":
                    names = names - {assertion_client.INTERNAL}
                return Namespace(tools=[Namespace(name=name) for name in names])

            async def call_tool(self, name, arguments):
                text = "Unknown product: missing" if "product_id" in arguments else "finite number"
                return types.CallToolResult(
                    isError=True, content=[types.TextContent(type="text", text=text)]
                )

        alice, bob = Session("alice"), Session("bob")

        @asynccontextmanager
        async def connection(url, bearer, **kwargs):
            self.assertEqual(kwargs["routing_header_file"], Path("/explicit-external-keys/provisioning"))
            yield alice if bearer == "alice" else bob, "2025-11-25"

        exact = AsyncMock()
        with patch.object(assertion_client, "restricted_directory", return_value=MCP_DIR), patch.object(
            assertion_client, "token", side_effect=lambda directory, identity: identity
        ), patch.object(assertion_client, "connect", connection), patch.object(
            assertion_client, "rejected", AsyncMock()
        ), patch.object(assertion_client, "direct_denial", AsyncMock()), patch.object(
            assertion_client, "exact", exact
        ), redirect_stdout(io.StringIO()):
            await assertion_client.authentication_assertions(
                Namespace(
                    phase="auth", token_directory=MCP_DIR, url="http://localhost/mcp",
                    routing_header_file=Path("/explicit-external-keys/provisioning"),
                )
            )
        exact.assert_any_await(bob, "calculator_add", {"a": 2, "b": 3}, {"result": 5.0})
        exact.assert_any_await(bob, "calculator_multiply", {"a": 6, "b": 7}, {"result": 42.0})
        exact.assert_any_await(bob, "catalog_lookup_product", {"product_id": "star-widget"}, assertion_client.PRODUCT)

    async def test_sdk_direct_denial_accepts_only_exact_http_400_mcp_error(self):
        from starlette.middleware.base import BaseHTTPMiddleware
        from starlette.responses import JSONResponse

        provisioning = "a" * 64
        observed = []

        async def denied(request, call_next):
            observed.append(request.headers.get("X-Agentgateway-MCP-Provisioning"))
            if request.method == "POST":
                message = types.JSONRPCMessage.model_validate_json(await request.body()).root
                if (
                    isinstance(message, types.JSONRPCRequest)
                    and message.method == "tools/call"
                    and message.params["name"] == assertion_client.INTERNAL
                ):
                    error = types.JSONRPCError(
                        jsonrpc="2.0", id=message.id,
                        error=types.ErrorData(code=-32602, message="unknown resource"),
                    )
                    return JSONResponse(error.model_dump(), status_code=400)
            return await call_next(request)

        app = calculator.server("authorization-http-test").streamable_http_app()
        app.add_middleware(BaseHTTPMiddleware, dispatch=denied)
        client_class = httpx.AsyncClient

        def client(**kwargs):
            return client_class(transport=httpx.ASGITransport(app=app), **kwargs)

        async with app.router.lifespan_context(app):
            with patch.object(assertion_client.httpx, "AsyncClient", side_effect=client):
                with patch.object(assertion_client, "routing_headers", return_value={
                    "X-Agentgateway-MCP-Provisioning": provisioning
                }), redirect_stdout(io.StringIO()):
                    await assertion_client.direct_denial(
                        "http://localhost/mcp", "local-test-value",
                        routing_header_file=Path("/explicit-external-keys/provisioning"),
                    )
        self.assertTrue(observed)
        self.assertTrue(all(value == provisioning for value in observed))

    async def test_generic_http_400_is_not_authorization_denial(self):
        response = httpx.Response(
            400, json={"jsonrpc": "2.0", "id": 1, "error": {"code": -32602, "message": "bad input"}},
            request=httpx.Request("POST", "http://localhost/mcp"),
        )
        error = httpx.HTTPStatusError("bad input", request=response.request, response=response)
        self.assertFalse(assertion_client.authorization_error(error))
        self.assertFalse(assertion_client.authorization_error(httpx.ConnectError("unreachable")))

    async def test_sdk_transport_authentication_requires_401(self):
        from starlette.applications import Starlette
        from starlette.responses import Response
        from starlette.routing import Route

        async def denied(request):
            return Response(status_code=401)

        app = Starlette(routes=[Route("/mcp", denied, methods=["POST", "GET", "DELETE"])])
        client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app))
        with patch.object(assertion_client.httpx, "AsyncClient", return_value=client):
            with redirect_stdout(io.StringIO()):
                await assertion_client.rejected("http://localhost/mcp", None, "missing")

    async def test_specific_rate_error_only(self):
        limited = types.CallToolResult(
            isError=True, content=[types.TextContent(type="text", text="rate limit exceeded (retry after 1s)")]
        )
        self.assertTrue(assertion_client.throttled(limited))
        unrelated = types.CallToolResult(
            isError=True, content=[types.TextContent(type="text", text="upstream error")]
        )
        with self.assertRaisesRegex(AssertionError, "Unexpected tool error"):
            assertion_client.throttled(unrelated)

    async def test_specific_jsonrpc_rate_error_only(self):
        class Session:
            async def call_tool(self, *args):
                raise McpError(types.ErrorData(code=-32003, message="rate limit exceeded"))

        self.assertTrue(await assertion_client.rate_call(Session()))

    async def test_authentication_requires_exact_401(self):
        from contextlib import asynccontextmanager

        @asynccontextmanager
        async def failure(url, bearer, **kwargs):
            response = httpx.Response(401, request=httpx.Request("POST", url))
            raise httpx.HTTPStatusError("unauthorized", request=response.request, response=response)
            yield

        with patch.object(assertion_client, "connect", failure), redirect_stdout(io.StringIO()):
            await assertion_client.rejected("http://localhost/mcp", None, "missing")

    async def test_phases_keep_authorization_and_rate_checks_isolated(self):
        from argparse import Namespace
        from unittest.mock import AsyncMock

        for phase, auth_count, rate_count in (("auth", 1, 0), ("rate", 0, 1), ("all", 1, 1)):
            auth = AsyncMock()
            rate = AsyncMock()
            with patch.object(assertion_client, "authentication_assertions", auth), patch.object(
                assertion_client, "rate_assertions", rate
            ):
                await assertion_client.assertions(Namespace(phase=phase))
            self.assertEqual(auth.await_count, auth_count)
            self.assertEqual(rate.await_count, rate_count)

    async def test_ready_phase_checks_exact_federated_discovery(self):
        from argparse import Namespace
        from contextlib import asynccontextmanager
        from unittest.mock import AsyncMock

        session = AsyncMock()
        session.list_tools.return_value = Namespace(
            tools=[Namespace(name=name) for name in assertion_client.TOOLS]
        )

        @asynccontextmanager
        async def connection(url, bearer, **kwargs):
            yield session, "2025-11-25"

        with patch.object(assertion_client, "restricted_directory", return_value=MCP_DIR):
            with patch.object(assertion_client, "token", return_value="local-test-value"):
                with patch.object(assertion_client, "connect", connection):
                    with redirect_stdout(io.StringIO()):
                        await assertion_client.assertions(
                            Namespace(phase="ready", token_directory=MCP_DIR, url="http://localhost/mcp")
                        )
        session.list_tools.assert_awaited_once()

    async def test_unrelated_transport_failure_is_not_authentication_denial(self):
        from contextlib import asynccontextmanager

        @asynccontextmanager
        async def broken(url, bearer, **kwargs):
            raise ExceptionGroup("transport", [httpx.ConnectError("unreachable")])
            yield

        with patch.object(assertion_client, "connect", broken):
            with self.assertRaisesRegex(AssertionError, "unrelated failure"):
                await assertion_client.rejected("http://localhost/mcp", None, "missing")


if __name__ == "__main__":
    unittest.main()
