"""Shared configuration for the SDK's Streamable HTTP servers."""

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse


def server(name: str) -> FastMCP:
    app = FastMCP(
        name,
        host="0.0.0.0",
        port=8000,
        streamable_http_path="/mcp",
        stateless_http=True,
        json_response=True,
        # ClusterIP hostnames are assigned by Kubernetes. These fixture backends
        # are internal; authentication and public Host validation belong upstream.
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=False
        ),
    )

    @app.custom_route("/readyz", methods=["GET"])
    async def readiness(request: Request) -> JSONResponse:
        return JSONResponse({"status": "ready"})

    return app
