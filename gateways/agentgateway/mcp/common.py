"""Shared configuration for the SDK's Streamable HTTP servers."""

import os

from mcp.server import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse


def server(name: str) -> MCPServer:
    app = MCPServer(name, version="1.0.0")

    @app.custom_route("/readyz", methods=["GET"])
    async def readiness(request: Request) -> JSONResponse:
        return JSONResponse({"status": "ready"})

    return app


def transport_security(service_name: str) -> TransportSecuritySettings:
    namespace = os.environ.get("POD_NAMESPACE", "default")
    service_host = f"{service_name}.{namespace}.svc.cluster.local"
    return TransportSecuritySettings(allowed_hosts=[service_host, f"{service_host}:8000"])
