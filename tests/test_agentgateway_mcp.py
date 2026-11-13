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
        self.directory = MCP_DIR / (".test-credentials-" + uuid.uuid4().hex)
        self.directory.mkdir(mode=0o700)

    def tearDown(self):
        shutil.rmtree(self.directory)

    def generate(self):
        with patch.object(jwt_tool, "restricted_directory", return_value=self.directory):
            jwt_tool.generate(self.directory, jwt_tool.ISSUER, jwt_tool.AUDIENCE, 900)

    def test_rsa_jwks_claims_rejections_and_permissions(self):
        output = io.StringIO()
        with redirect_stdout(output):
            self.generate()
        self.assertEqual(output.getvalue(), "")
        jwks = json.loads((self.directory / "jwks.json").read_text())
        public_key = jwt.PyJWK.from_dict(jwks["keys"][0]).key
        for identity in ("alice", "bob"):
            claims = jwt.decode(
                assertion_client.token(self.directory, identity), public_key,
                algorithms=["RS256"], issuer=jwt_tool.ISSUER, audience=jwt_tool.AUDIENCE,
            )
            self.assertEqual(claims["sub"], identity)
            self.assertLessEqual(claims["exp"] - claims["iat"], 900)
        with self.assertRaises(jwt.ExpiredSignatureError):
            jwt.decode(assertion_client.token(self.directory, "expired"), public_key,
                       algorithms=["RS256"], audience=jwt_tool.AUDIENCE)
        with self.assertRaises(jwt.InvalidSignatureError):
            jwt.decode(assertion_client.token(self.directory, "invalid"), public_key,
                       algorithms=["RS256"], audience=jwt_tool.AUDIENCE)
        for path in self.directory.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_renewal_keeps_provisioned_public_key(self):
        self.generate()
        key = (self.directory / "private.pem").read_bytes()
        jwks = (self.directory / "jwks.json").read_bytes()
        self.generate()
        self.assertEqual((self.directory / "private.pem").read_bytes(), key)
        self.assertEqual((self.directory / "jwks.json").read_bytes(), jwks)

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
        private.write_text("not a key")
        private.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "private"):
            self.generate()


class ClientCliTests(unittest.TestCase):
    def test_rate_phase_accepts_token_dir_alias_and_burst_twelve(self):
        from unittest.mock import AsyncMock

        argv = [
            "assertion_client.py", "--token-dir", "/explicit-external-keys",
            "--phase", "rate", "--rate-capacity", "12",
        ]
        assertions = AsyncMock()
        with patch.object(sys, "argv", argv), patch.object(assertion_client, "assertions", assertions):
            with redirect_stdout(io.StringIO()):
                self.assertEqual(assertion_client.main(), 0)
        args = assertions.await_args.args[0]
        self.assertEqual(args.token_directory, Path("/explicit-external-keys"))
        self.assertEqual(args.rate_capacity, 12)
        self.assertEqual(args.phase, "rate")


class AssertionClientTests(unittest.IsolatedAsyncioTestCase):
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
        async def failure(url, bearer):
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
        async def connection(url, bearer):
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
        async def broken(url, bearer):
            raise ExceptionGroup("transport", [httpx.ConnectError("unreachable")])
            yield

        with patch.object(assertion_client, "connect", broken):
            with self.assertRaisesRegex(AssertionError, "unrelated failure"):
                await assertion_client.rejected("http://localhost/mcp", None, "missing")


if __name__ == "__main__":
    unittest.main()
