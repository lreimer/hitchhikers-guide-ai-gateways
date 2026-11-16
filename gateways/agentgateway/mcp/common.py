"""Shared configuration for the SDK's Streamable HTTP servers."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
import os

from mcp.server import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route
import uvicorn


def allowed_hosts(name: str) -> list[str]:
    namespace = os.environ.get("POD_NAMESPACE")
    if not namespace:
        return [
            "127.0.0.1",
            "127.0.0.1:*",
            "localhost",
            "localhost:*",
            "[::1]",
            "[::1]:*",
        ]
    service = f"agentgateway-mcp-{name}"
    return [
        "127.0.0.1:*",
        f"{service}:8000",
        f"{service}.{namespace}.svc.cluster.local:8000",
    ]


def app(mcp: MCPServer) -> Starlette:
    @asynccontextmanager
    async def lifespan(_: Starlette) -> AsyncIterator[None]:
        async with mcp.session_manager.run():
            yield

    async def readiness(_: Request) -> JSONResponse:
        return JSONResponse({"status": "ready"})

    return Starlette(
        routes=[
            Route("/readyz", readiness, methods=["GET"]),
            Mount(
                "/",
                app=mcp.streamable_http_app(
                    streamable_http_path="/mcp",
                    host="0.0.0.0",
                    stateless_http=True,
                    json_response=True,
                    transport_security=TransportSecuritySettings(
                        allowed_hosts=allowed_hosts(mcp.name),
                    ),
                ),
            ),
        ],
        lifespan=lifespan,
    )


def run(mcp: MCPServer) -> None:
    uvicorn.run(app(mcp), host="0.0.0.0", port=8000)


def server(name: str) -> MCPServer:
    return MCPServer(name, version="0.1.0")
