"""Generate local demo credentials without printing tokens or private material."""

import argparse
import base64
import json
import os
from pathlib import Path
import stat
import sys
import time

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import jwt


ISSUER = "https://agentgateway.demo.invalid"
AUDIENCE = "agentgateway-mcp-demo"
KEY_ID = "agentgateway-mcp-demo"


def b64_integer(number: int) -> str:
    raw = number.to_bytes((number.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def restricted_directory(path: Path) -> Path:
    if not path.is_absolute():
        raise ValueError("Credential directory must be an explicit absolute external path")
    # Resolve both paths to reject a symlink pointing into repository artifacts.
    directory = path.resolve()
    source = Path(__file__).resolve()
    repository = next(
        (ancestor for ancestor in source.parents if (ancestor / ".git").exists()),
        source.parent,
    )
    if directory == repository or repository in directory.parents:
        raise ValueError("Credential directory must be outside the repository")
    if path.is_symlink():
        raise ValueError("Credential directory must not be a symlink")
    if not directory.exists():
        directory.mkdir(mode=0o700, parents=True)
    info = directory.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("Credential directory must be owned by you with mode 0700")
    return directory


def write_private(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
            raise ValueError("Credential files must be regular files owned by you")
        os.fchmod(fd, 0o600)
        os.ftruncate(fd, 0)
        with os.fdopen(fd, "wb", closefd=False) as output:
            output.write(data)
    finally:
        os.close(fd)


def generate(directory: Path, issuer: str, audience: str, lifetime: int) -> None:
    if not 60 <= lifetime <= 3600:
        raise ValueError("Token lifetime must be between 60 and 3600 seconds")
    directory = restricted_directory(directory)
    private_path = directory / "private.pem"
    if private_path.exists():
        info = private_path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077
        ):
            raise ValueError("Existing private.pem must be a private, owned regular file")
        key = serialization.load_pem_private_key(private_path.read_bytes(), None)
        if not isinstance(key, rsa.RSAPrivateKey) or key.key_size < 2048:
            raise ValueError("Existing private.pem must be an RSA key of at least 2048 bits")
    else:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        write_private(
            private_path,
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ),
        )
    public = key.public_key().public_numbers()
    jwks = {
        "keys": [{
            "kty": "RSA", "kid": KEY_ID, "use": "sig", "alg": "RS256",
            "n": b64_integer(public.n), "e": b64_integer(public.e),
        }]
    }
    write_private(directory / "jwks.json", (json.dumps(jwks, indent=2) + "\n").encode())
    now = int(time.time())
    for identity in ("alice", "bob", "expired", "invalid"):
        claims = {
            "iss": issuer, "aud": audience,
            "sub": identity if identity in ("alice", "bob") else "alice",
            "iat": now - 120 if identity == "expired" else now,
            "exp": now - 60 if identity == "expired" else now + lifetime,
        }
        signing_key = (
            rsa.generate_private_key(public_exponent=65537, key_size=2048)
            if identity == "invalid" else key
        )
        token = jwt.encode(claims, signing_key, algorithm="RS256", headers={"kid": KEY_ID})
        write_private(directory / f"{identity}.jwt", token.encode() + b"\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["generate"])
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--issuer", default=ISSUER)
    parser.add_argument("--audience", default=AUDIENCE)
    parser.add_argument("--lifetime", type=int, default=900)
    args = parser.parse_args()
    try:
        generate(args.directory, args.issuer, args.audience, args.lifetime)
    except (ValueError, OSError):
        print("Credential generation failed: check external path, ownership, permissions, and lifetime.", file=sys.stderr)
        return 1
    print("Generated restricted credentials and public JWKS; existing signing key preserved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
